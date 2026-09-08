///|
/// What a storage backend must be able to do.
///
/// This is the raw seam -- OpenDAL's `Access` rather than its `Operator`. Two
/// obligations on an implementor, and both are things a hand-written backend
/// gets wrong:
///
/// - **Paths arrive normalised and validated.** `Operator` runs every path
///   through `validate` before it gets here: no leading `/`, no `..`, no `//`,
///   no `.`, and a trailing `/` exactly when the caller meant a directory. A
///   backend must not re-normalise, and may concatenate the path onto its own
///   root without escaping it -- which is precisely why validation is not
///   optional and not the backend's job.
///
/// - **Nothing from the backend's own dependencies escapes.** Every failure
///   leaves as a `SosError`, or a caller's `catch` sees a type from a package it
///   never imported.
///
/// Implement it and hand the value to `Operator::new`; callers go through the
/// operator, not through this.
pub(open) trait Store {
  /// Who this is and what it can do.
  ///
  /// Must be cheap and pure: `Operator::new` calls it once and caches the
  /// answer, so a backend cannot change its mind later.
  fn info(Self) -> StoreInfo

  /// The whole object, or the requested range of it.
  ///
  /// `NotFound` when absent, `IsADirectory` when the path names a directory,
  /// `RangeNotSatisfied` when the range starts past the end.
  async fn read(Self, String, ReadOptions) -> Bytes raise SosError

  /// Replace, append to, or create the object at this path.
  ///
  /// Creates every missing ancestor directory. A filesystem needs `mkdir -p`
  /// here; an object store needs nothing. Making that the backend's problem is
  /// what lets `write("a/b/c.txt")` mean the same thing on all three.
  async fn write(Self, String, Bytes, WriteOptions) -> Unit raise SosError

  /// Metadata only. `NotFound` when absent.
  async fn stat(Self, String) -> Metadata raise SosError

  /// The contents of a directory, in ascending path order.
  ///
  /// The path is a directory path; `""` is the root. Non-recursive returns the
  /// immediate children, with a `Dir` entry per child directory whether or not
  /// the backend has real ones. Recursive returns every descendant, directories
  /// included, still in ascending path order.
  ///
  /// A directory with nothing under it returns `[]`. It does NOT raise
  /// `NotFound`: a filesystem could tell absent from empty and an object store
  /// cannot, and the portable answer is the one both can give.
  async fn list(Self, String, ListOptions) -> Array[Entry] raise SosError

  /// Remove.
  ///
  /// An absent path is success, not `NotFound` -- delete is idempotent, so a
  /// retry after a half-seen failure does not have to distinguish. A non-empty
  /// directory without `recursive` raises `DirectoryNotEmpty`.
  async fn delete(Self, String, DeleteOptions) -> Unit raise SosError

  /// `mkdir -p`. Idempotent. The path ends in `/`.
  async fn create_dir(Self, String) -> Unit raise SosError
  async fn copy(Self, String, String) -> Unit raise SosError = _
  async fn rename(Self, String, String) -> Unit raise SosError = _
}

///|
/// Read the source and write it at the destination.
///
/// Correct for every backend and native to none, which is exactly why it is a
/// default rather than a required method: a backend without a server-side copy
/// would write this, and a backend with one should override. `FsStore` keeps it,
/// because `moonbitlang/async/fs` has no `copyfile`; `MemoryStore` and
/// `IdbStore` override, because for them a copy is one insert.
///
/// Neither atomic nor cheap: the whole object goes through memory, and a reader
/// at the destination sees the old bytes until the write lands.
/// `Capability::copy` says the operation exists, not that it is either of those.
impl Store with fn copy(self, from, to) {
  let meta = self.stat(from)
  guard meta.mode is File else {
    raise SosError::new(
      IsADirectory,
      operation="copy",
      path=from,
      message="copy source is a directory",
    )
  }
  let content = self.read(from, ReadOptions::default())
  self.write(to, content, {
    ..WriteOptions::default(),
    content_type: meta.content_type,
  })
}

///|
/// Copy, then delete the source.
///
/// A backend with a real rename should override -- every filesystem has one, and
/// for the two object stores it is an insert plus a delete. Both because that is
/// one operation instead of three, and because this one has both copies present
/// in between.
impl Store with fn rename(self, from, to) {
  self.copy(from, to)
  self.delete(from, DeleteOptions::default())
}
