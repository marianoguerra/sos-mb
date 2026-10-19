///|
/// A store backed by IndexedDB, over whatever `Conn` reached it.
///
/// Object-style, like `MemoryStore` and unlike `FsStore`: there is one flat key
/// space and directories are reconstructed from it by
/// `@sos.group_flat_listing`. What that shares with the memory backend is not a
/// coincidence -- it is the same core function, so the two answer `list`
/// identically and the conformance suite can hold them to it.
///
/// The one thing that is genuinely IndexedDB's own is `list`: a cursor over
/// `IDBKeyRange.bound(prefix, prefix + "\u{FFFF}")`, which is why `@sos.validate`
/// forbids `U+FFFF` in a path. Nothing outside the prefix is read.
pub struct IdbStore {
  conn : &Conn
}

///|
/// The store an open connection speaks for.
pub fn IdbStore::over(conn : &Conn) -> IdbStore {
  { conn, }
}

///|
/// The database name this store is anchored in.
pub fn IdbStore::database(self : IdbStore) -> String {
  self.conn.name()
}

///|
/// Hand the connection underneath back. Idempotent.
///
/// Here, and not only on the concrete connection, because `@indexeddb.open` and
/// `@idbwasm.open` both answer with an `IdbStore` and keep the `Conn` to
/// themselves. Without this, a caller who took the one-call opener has nothing
/// to close -- so a program that swaps one store for another at runtime drops a
/// live database connection every time it switches.
pub async fn IdbStore::close(self : IdbStore) -> Unit raise @sos.SosError {
  self.conn.close()
}

///|
/// The exclusive upper bound of the key range that holds everything under
/// `prefix`.
///
/// Sound because `@sos.validate` rejects `U+FFFF`, and because IndexedDB orders
/// strings by UTF-16 code unit -- so a key with an astral character in it starts
/// with a surrogate below `0xFFFF` and stays inside the bound. `@sos.path_compare`
/// uses the same ordering for the same reason.
pub fn upper_bound(prefix : String) -> String {
  prefix + "\u{FFFF}"
}

///|
/// Every record under `prefix`, metadata only, as listing input.
///
/// The object bytes never travel: `scan` sends back names, sizes and
/// timestamps, so listing a directory of large blobs costs what listing their
/// names costs.
async fn IdbStore::index(
  self : IdbStore,
  prefix : String,
  operation~ : String,
) -> Array[@sos.Entry] raise @sos.SosError {
  let encoded = self.conn.scan(prefix, upper_bound(prefix), operation~)
  decode_rows(encoded, prefix, operation~)
}

///|
/// The rows `Conn::scan` answered, as entries.
///
/// Public because it is the shape both boundaries have to produce, and a
/// backend author who gets it wrong should find out from this package's tests
/// rather than from a browser.
pub fn decode_rows(
  encoded : String,
  prefix : String,
  operation~ : String,
) -> Array[@sos.Entry] raise @sos.SosError {
  let rows = @json.parse(encoded) catch {
    err =>
      raise @sos.SosError::new(
        @sos.Unexpected,
        operation~,
        path=prefix,
        message="could not read the cursor result: \{err}",
      )
  }
  let out : Array[@sos.Entry] = []
  guard rows is Array(items) else { return out }
  for item in items {
    guard item is Object(fields) else { continue }
    guard fields.get("p") is Some(String(path)) else { continue }
    let is_dir = fields.get("d") is Some(True)
    let modified = match fields.get("m") {
      Some(Number(value, ..)) => Some(value.to_int64())
      _ => None
    }
    let metadata = if is_dir {
      @sos.Metadata::dir(last_modified?=modified)
    } else {
      let size = match fields.get("n") {
        Some(Number(value, ..)) => value.to_int64()
        _ => 0L
      }
      let content_type = match fields.get("c") {
        Some(String(value)) => Some(value)
        _ => None
      }
      @sos.Metadata::file(size, content_type?, last_modified?=modified)
    }
    out.push({ path, metadata, })
  }
  out
}

///|
pub impl @sos.Store for IdbStore with fn info(self) {
  {
    scheme: "indexeddb",
    root: "",
    name: self.conn.name(),
    capability: {
      ..@sos.Capability::none(),
      read: true,
      read_with_range: true,
      write: true,
      // `write_can_append` stays false. It could be faked with a read, a concat
      // and a put, but each of those is its own transaction, so two appends
      // racing would lose one. Refusing is honest; pretending is not.
      write_with_content_type: true,
      write_with_if_not_exists: true,
      stat: true,
      list: true,
      list_with_recursive: true,
      list_with_limit: true,
      list_with_start_after: true,
      delete: true,
      delete_with_recursive: true,
      create_dir: true,
      copy: true,
      rename: true,
      shared: true,
    },
  }
}

///|
pub impl @sos.Store for IdbStore with fn read(self, path, opts) {
  let record = match self.conn.get(path, operation="read") {
    Some(record) => record
    None => raise @sos.SosError::new(@sos.NotFound, operation="read", path~)
  }
  guard !record.is_dir else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="read", path~)
  }
  let data = record.data
  match opts.range {
    None => data
    Some(range) =>
      match range.resolve(data.length().to_int64()) {
        None =>
          raise @sos.SosError::new(
            @sos.RangeNotSatisfied,
            operation="read",
            path~,
            message="the object is \{data.length()} bytes",
          )
        Some((offset, length)) => {
          let start = offset.to_int()
          data[start:start + length.to_int()].to_owned()
        }
      }
  }
}

///|
pub impl @sos.Store for IdbStore with fn write(self, path, data, opts) {
  if opts.if_not_exists && self.conn.get(path, operation="write") is Some(_) {
    raise @sos.SosError::new(@sos.AlreadyExists, operation="write", path~)
  }
  self.conn.put(
    path,
    data,
    content_type=opts.content_type.unwrap_or(""),
    is_dir=false,
    operation="write",
  )
}

///|
pub impl @sos.Store for IdbStore with fn stat(self, path) {
  match self.conn.get(path, operation="stat") {
    Some(record) => record.to_metadata()
    None =>
      // An implicit directory: nobody stored a marker, but something lives under
      // it, so it exists as surely as it does in a listing.
      if @sos.is_dir_path(path) &&
        !self.index(path, operation="stat").is_empty() {
        @sos.Metadata::dir()
      } else {
        raise @sos.SosError::new(@sos.NotFound, operation="stat", path~)
      }
  }
}

///|
pub impl @sos.Store for IdbStore with fn list(self, path, opts) {
  let held = self.index(path, operation="list")
  @sos.group_flat_listing(path, held.iter(), opts)
}

///|
pub impl @sos.Store for IdbStore with fn delete(self, path, opts) {
  if @sos.is_dir_path(path) {
    if !opts.recursive {
      let children = self
        .index(path, operation="delete")
        .filter(entry => entry.path != path)
      guard children.is_empty() else {
        raise @sos.SosError::new(
          @sos.DirectoryNotEmpty,
          operation="delete",
          path~,
          message="pass recursive to remove it and everything under it",
        )
      }
      self.conn.delete_one(path, operation="delete")
    } else {
      // One range delete rather than a cursor and N deletes: the same bound the
      // listing uses, so the two can never disagree about what is under a path.
      self.conn.delete_range(path, upper_bound(path), operation="delete")
    }
  } else {
    self.conn.delete_one(path, operation="delete")
  }
}

///|
pub impl @sos.Store for IdbStore with fn create_dir(self, path) {
  for dir in @sos.ancestors(path) {
    if self.conn.get(dir, operation="create_dir") is None {
      self.conn.put(
        dir,
        b"",
        content_type="",
        is_dir=true,
        operation="create_dir",
      )
    }
  }
  if self.conn.get(path, operation="create_dir") is None {
    self.conn.put(
      path,
      b"",
      content_type="",
      is_dir=true,
      operation="create_dir",
    )
  }
}

///|
/// One read and one put, instead of the trait default's read through a caller.
pub impl @sos.Store for IdbStore with fn copy(self, from, to) {
  let record = match self.conn.get(from, operation="copy") {
    Some(record) => record
    None => raise @sos.SosError::new(@sos.NotFound, operation="copy", path=from)
  }
  guard !record.is_dir else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="copy", path=from)
  }
  self.conn.put(
    to,
    record.data,
    content_type=record.content_type,
    is_dir=false,
    operation="copy",
  )
}

///|
/// A put and a delete.
///
/// Not atomic -- they are separate transactions, and IndexedDB has no rename --
/// but it beats the default's read-through-the-caller by a round trip, and by
/// not holding the object in MoonBit memory in between.
pub impl @sos.Store for IdbStore with fn rename(self, from, to) {
  @sos.Store::copy(self, from, to)
  self.conn.delete_one(from, operation="rename")
}

///|
pub extend IdbStore with @sos.Store::{
  stat,
  read,
  info,
  list,
  create_dir,
  copy,
  rename,
  delete,
  write,
}
