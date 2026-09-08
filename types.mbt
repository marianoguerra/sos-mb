///|
/// What a path denotes.
///
/// `Unknown` is not a placeholder for "we did not look": it is what a filesystem
/// answers for a socket, a fifo or a device node, which a store can see and
/// cannot serve.
pub(all) enum EntryMode {
  File
  Dir
  Unknown
} derive(Eq, Debug)

///|
/// What a store knows about one path.
///
/// Everything but `mode` is optional, because backends genuinely differ: a
/// filesystem has no content type and no etag, an object store has both. A
/// caller that needs one must check the backend's `Capability` first, or
/// tolerate `None`.
pub(all) struct Metadata {
  mode : EntryMode
  /// Bytes. Zero for a directory.
  content_length : Int64
  content_type : String?
  etag : String?
  /// Unix epoch milliseconds where the backend has a clock. Monotone within one
  /// store, and NOT comparable across stores: `MemoryStore` counts writes, it
  /// does not read a clock.
  last_modified : Int64?
} derive(Eq, Debug)

///|
pub fn Metadata::file(
  content_length : Int64,
  content_type? : String,
  etag? : String,
  last_modified? : Int64,
) -> Metadata {
  { mode: File, content_length, content_type, etag, last_modified, }
}

///|
pub fn Metadata::dir(last_modified? : Int64) -> Metadata {
  {
    mode: Dir,
    content_length: 0L,
    content_type: None,
    etag: None,
    last_modified,
  }
}

///|
pub fn Metadata::is_dir(self : Metadata) -> Bool {
  self.mode is Dir
}

///|
pub fn Metadata::is_file(self : Metadata) -> Bool {
  self.mode is File
}

///|
/// One result of `list`: a path and what is known about it.
///
/// `path` is relative to the store root and is the exact string `read` and
/// `stat` will accept. A directory entry's path ends in `/`; a file's does not.
/// That invariant is what lets a caller recurse without a second `stat`.
pub(all) struct Entry {
  path : String
  metadata : Metadata
} derive(Eq, Debug)

///|
/// The last segment. Keeps the trailing `/` for a directory.
pub fn Entry::name(self : Entry) -> String {
  basename(self.path)
}

///|
pub fn Entry::is_dir(self : Entry) -> Bool {
  self.metadata.is_dir()
}

///|
/// What a backend can do.
///
/// Declared rather than discovered, and checked by `Operator` before the call
/// reaches the store, so an unsupported option fails with the operation's own
/// name instead of somewhere inside a backend.
///
/// The conformance suite reads this to decide which checks to run, and asserts
/// the inverse too: every `false` flag must produce `Unsupported`. A backend
/// cannot under-declare its way out of a check.
pub(all) struct Capability {
  read : Bool
  read_with_range : Bool
  write : Bool
  write_can_append : Bool
  write_with_content_type : Bool
  write_with_if_not_exists : Bool
  stat : Bool
  list : Bool
  list_with_recursive : Bool
  list_with_limit : Bool
  list_with_start_after : Bool
  delete : Bool
  delete_with_recursive : Bool
  create_dir : Bool
  copy : Bool
  rename : Bool
  /// True when a second operator over the same root -- in another process,
  /// another tab -- sees these writes. False for `MemoryStore`.
  shared : Bool
} derive(Eq, Debug)

///|
/// Everything off.
///
/// Build a real one with struct update, so adding a field to `Capability` does
/// not silently turn it on everywhere:
/// `{ ..Capability::none(), read: true, write: true }`.
pub fn Capability::none() -> Capability {
  {
    read: false,
    read_with_range: false,
    write: false,
    write_can_append: false,
    write_with_content_type: false,
    write_with_if_not_exists: false,
    stat: false,
    list: false,
    list_with_recursive: false,
    list_with_limit: false,
    list_with_start_after: false,
    delete: false,
    delete_with_recursive: false,
    create_dir: false,
    copy: false,
    rename: false,
    shared: false,
  }
}

///|
/// Who a store is.
///
/// Cheap and pure: `Operator::new` calls `Store::info` once at construction and
/// caches the answer, so it must not do I/O.
pub(all) struct StoreInfo {
  /// "memory", "fs", "indexeddb".
  scheme : String
  /// Where the store is anchored. Display only; never concatenated with a store
  /// path by anything outside the backend that produced it.
  root : String
  /// Bucket, database or namespace. Empty when the backend has none.
  name : String
  capability : Capability
} derive(Eq, Debug)
