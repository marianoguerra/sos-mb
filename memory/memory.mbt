///|
/// One stored object.
priv struct Record {
  data : Bytes
  content_type : String?
  last_modified : Int64
  mode : @sos.EntryMode
}

///|
/// A store that keeps everything in a `Map`, on every backend.
///
/// Directories are implicit, the way they are in an object store: `write`
/// records nothing but the object, and `list` reconstructs the tree from the key
/// space. `create_dir` does insert a marker, because an explicitly created empty
/// directory has nothing to reconstruct it from and a caller that made one
/// expects to see it.
///
/// Useful as a test double, as a cache, and as the reference the other backends
/// are read against -- it is the only one whose behaviour is entirely visible in
/// this file.
struct MemoryStore {
  entries : Map[String, Record]
  /// A counter, not a clock.
  ///
  /// `Metadata::last_modified` only promises to be monotone within one store,
  /// and the core has no clock that works on every backend. Counting writes
  /// keeps the ordering honest without pretending to a wall time this store
  /// cannot read.
  mut clock : Int64
  name : String
}

///|
pub fn MemoryStore::new(name? : String = "") -> MemoryStore {
  { entries: Map([]), clock: 0L, name, }
}

///|
/// How many records are held, directory markers included.
pub fn MemoryStore::size(self : MemoryStore) -> Int {
  self.entries.length()
}

///|
fn MemoryStore::tick(self : MemoryStore) -> Int64 {
  self.clock = self.clock + 1L
  self.clock
}

///|
fn Record::to_metadata(self : Record) -> @sos.Metadata {
  match self.mode {
    Dir => @sos.Metadata::dir(last_modified=self.last_modified)
    _ =>
      @sos.Metadata::file(
        self.data.length().to_int64(),
        content_type?=self.content_type,
        last_modified=self.last_modified,
      )
  }
}

///|
/// Everything held, as listing input.
fn MemoryStore::snapshot(self : MemoryStore) -> Array[@sos.Entry] {
  let out : Array[@sos.Entry] = []
  for path, record in self.entries {
    out.push({ path, metadata: record.to_metadata(), })
  }
  out
}

///|
/// Is there anything strictly under this directory?
fn MemoryStore::has_children(self : MemoryStore, dir : String) -> Bool {
  for path, _ in self.entries {
    if path != dir && path.has_prefix(dir) {
      return true
    }
  }
  false
}

///|
pub impl @sos.Store for MemoryStore with fn info(self) {
  {
    scheme: "memory",
    root: "",
    name: self.name,
    capability: {
      ..@sos.Capability::none(),
      read: true,
      read_with_range: true,
      write: true,
      write_can_append: true,
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
      // `shared` stays false: two `MemoryStore` values share nothing, and
      // neither does a second process.
    },
  }
}

///|
pub impl @sos.Store for MemoryStore with fn read(self, path, opts) {
  let record = match self.entries.get(path) {
    Some(record) => record
    None => raise @sos.SosError::new(@sos.NotFound, operation="read", path~)
  }
  guard record.mode is File else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="read", path~)
  }
  match opts.range {
    None => record.data
    Some(range) =>
      match range.resolve(record.data.length().to_int64()) {
        None =>
          raise @sos.SosError::new(
            @sos.RangeNotSatisfied,
            operation="read",
            path~,
            message="the object is \{record.data.length()} bytes",
          )
        Some((offset, length)) => {
          let start = offset.to_int()
          record.data[start:start + length.to_int()].to_owned()
        }
      }
  }
}

///|
pub impl @sos.Store for MemoryStore with fn write(self, path, data, opts) {
  let existing = self.entries.get(path)
  if opts.if_not_exists && existing is Some(_) {
    raise @sos.SosError::new(@sos.AlreadyExists, operation="write", path~)
  }
  if existing is Some(record) && record.mode is Dir {
    raise @sos.SosError::new(@sos.IsADirectory, operation="write", path~)
  }
  let data = if opts.append {
    match existing {
      Some(record) => record.data + data
      None => data
    }
  } else {
    data
  }
  // An object store needs no ancestors, but an empty directory the caller made
  // on purpose should not vanish because a sibling file appeared. Markers are
  // only added by `create_dir`; nothing here removes them.
  self.entries[path] = {
    data,
    content_type: opts.content_type,
    last_modified: self.tick(),
    mode: File,
  }
}

///|
pub impl @sos.Store for MemoryStore with fn stat(self, path) {
  match self.entries.get(path) {
    Some(record) => record.to_metadata()
    None =>
      // A directory nobody created explicitly still exists as long as something
      // is under it, exactly as it does in a listing.
      if @sos.is_dir_path(path) && self.has_children(path) {
        @sos.Metadata::dir()
      } else {
        raise @sos.SosError::new(@sos.NotFound, operation="stat", path~)
      }
  }
}

///|
pub impl @sos.Store for MemoryStore with fn list(self, path, opts) {
  @sos.group_flat_listing(path, self.snapshot().iter(), opts)
}

///|
pub impl @sos.Store for MemoryStore with fn delete(self, path, opts) {
  if @sos.is_dir_path(path) {
    if !opts.recursive && self.has_children(path) {
      raise @sos.SosError::new(
        @sos.DirectoryNotEmpty,
        operation="delete",
        path~,
        message="pass recursive to remove it and everything under it",
      )
    }
    let doomed : Array[String] = []
    for key, _ in self.entries {
      if key == path || (opts.recursive && key.has_prefix(path)) {
        doomed.push(key)
      }
    }
    for key in doomed {
      self.entries.remove(key)
    }
  } else {
    // Absent is success: delete is idempotent.
    self.entries.remove(path)
  }
}

///|
pub impl @sos.Store for MemoryStore with fn create_dir(self, path) {
  if self.entries.get(path) is Some(record) && record.mode is Dir {
    return
  }
  for dir in @sos.ancestors(path) {
    if !self.entries.contains(dir) {
      self.entries[dir] = {
        data: b"",
        content_type: None,
        last_modified: self.tick(),
        mode: Dir,
      }
    }
  }
  self.entries[path] = {
    data: b"",
    content_type: None,
    last_modified: self.tick(),
    mode: Dir,
  }
}

///|
/// One insert. Overrides the read-then-write default, which would copy the bytes
/// through a caller's memory for no reason when they are already here.
pub impl @sos.Store for MemoryStore with fn copy(self, from, to) {
  let record = match self.entries.get(from) {
    Some(record) => record
    None => raise @sos.SosError::new(@sos.NotFound, operation="copy", path=from)
  }
  guard record.mode is File else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="copy", path=from)
  }
  self.entries[to] = { ..record, last_modified: self.tick(), }
}

///|
/// An insert and a remove, with no moment where both copies exist.
pub impl @sos.Store for MemoryStore with fn rename(self, from, to) {
  let record = match self.entries.get(from) {
    Some(record) => record
    None =>
      raise @sos.SosError::new(@sos.NotFound, operation="rename", path=from)
  }
  guard record.mode is File else {
    raise @sos.SosError::new(@sos.IsADirectory, operation="rename", path=from)
  }
  self.entries[to] = { ..record, last_modified: self.tick(), }
  self.entries.remove(from)
}
