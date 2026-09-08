///|
/// A store backed by the browser's IndexedDB.
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
struct IdbStore {
  db : Database
  name : String
}

///|
/// Open, or create, `database` and use the object store `store` inside it.
pub async fn IdbStore::open(
  database? : String = "sos",
  store? : String = "objects",
) -> IdbStore raise @sos.SosError {
  guard has_indexeddb() else {
    raise @sos.SosError::new(
      @sos.ConfigInvalid,
      operation="open",
      message="this context has no indexedDB",
    )
  }
  let db = open_db(database, store).wait() catch {
    err =>
      raise @sos.SosError::new(
        @sos.Unexpected,
        operation="open",
        message="could not open '\{database}': \{err}",
      )
  }
  { db, name: database, }
}

///|
/// The database name this store is anchored in.
pub fn IdbStore::database(self : IdbStore) -> String {
  self.name
}

///|
/// The exclusive upper bound of the key range that holds everything under
/// `prefix`.
///
/// Sound because `@sos.validate` rejects `U+FFFF`, and because IndexedDB orders
/// strings by UTF-16 code unit -- so a key with an astral character in it starts
/// with a surrogate below `0xFFFF` and stays inside the bound. `@sos.path_compare`
/// uses the same ordering for the same reason.
fn upper_bound(prefix : String) -> String {
  prefix + "\u{FFFF}"
}

///|
async fn IdbStore::fetch(
  self : IdbStore,
  path : String,
  operation~ : String,
) -> Record? raise @sos.SosError {
  let record = self.db.get(path).wait() catch {
      err => raise unexpected(err, operation~, path~)
    }
  if record.is_missing() {
    None
  } else {
    Some(record)
  }
}

///|
fn unexpected(
  err : Error,
  operation~ : String,
  path~ : String,
) -> @sos.SosError {
  match err {
    @sos.SosError(_) as sos => sos
    other =>
      @sos.SosError::new(
        @sos.Unexpected,
        operation~,
        path~,
        message=other.to_string(),
      )
  }
}

///|
fn Record::to_metadata(self : Record) -> @sos.Metadata {
  let modified = self.modified().to_int64()
  if self.is_dir() {
    @sos.Metadata::dir(last_modified=modified)
  } else {
    let ctype = self.content_type()
    @sos.Metadata::file(
      self.data().length().to_int64(),
      content_type?=if ctype == "" { None } else { Some(ctype) },
      last_modified=modified,
    )
  }
}

///|
/// Write one record.
async fn IdbStore::store(
  self : IdbStore,
  path : String,
  data : Bytes,
  content_type : String?,
  is_dir~ : Bool,
  operation~ : String,
) -> Unit raise @sos.SosError {
  self.db.put(path, data, content_type.unwrap_or(""), now_ms(), is_dir).wait() catch {
    err => raise unexpected(err, operation~, path~)
  }
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
  let encoded = self.db.scan(prefix, upper_bound(prefix)).wait() catch {
      err => raise unexpected(err, operation~, path=prefix)
    }
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
    name: self.name,
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
  let record = match self.fetch(path, operation="read") {
    Some(record) => record
    None => raise @sos.SosError::new(@sos.NotFound, operation="read", path~)
  }
  guard !record.is_dir() else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="read", path~)
  }
  let data = record.data()
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
  if opts.if_not_exists && self.fetch(path, operation="write") is Some(_) {
    raise @sos.SosError::new(@sos.AlreadyExists, operation="write", path~)
  }
  self.store(path, data, opts.content_type, is_dir=false, operation="write")
}

///|
pub impl @sos.Store for IdbStore with fn stat(self, path) {
  match self.fetch(path, operation="stat") {
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
      self.db.delete_one(path).wait() catch {
        err => raise unexpected(err, operation="delete", path~)
      }
    } else {
      // One range delete rather than a cursor and N deletes: the same bound the
      // listing uses, so the two can never disagree about what is under a path.
      self.db.delete_range(path, upper_bound(path)).wait() catch {
        err => raise unexpected(err, operation="delete", path~)
      }
    }
  } else {
    self.db.delete_one(path).wait() catch {
      err => raise unexpected(err, operation="delete", path~)
    }
  }
}

///|
pub impl @sos.Store for IdbStore with fn create_dir(self, path) {
  for dir in @sos.ancestors(path) {
    if self.fetch(dir, operation="create_dir") is None {
      self.store(dir, b"", None, is_dir=true, operation="create_dir")
    }
  }
  if self.fetch(path, operation="create_dir") is None {
    self.store(path, b"", None, is_dir=true, operation="create_dir")
  }
}

///|
/// One read and one put, instead of the trait default's read through a caller.
pub impl @sos.Store for IdbStore with fn copy(self, from, to) {
  let record = match self.fetch(from, operation="copy") {
    Some(record) => record
    None => raise @sos.SosError::new(@sos.NotFound, operation="copy", path=from)
  }
  guard !record.is_dir() else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="copy", path=from)
  }
  let ctype = record.content_type()
  self.store(
    to,
    record.data(),
    if ctype == "" {
      None
    } else {
      Some(ctype)
    },
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
  self.copy(from, to)
  self.db.delete_one(from).wait() catch {
    err => raise unexpected(err, operation="rename", path=from)
  }
}
