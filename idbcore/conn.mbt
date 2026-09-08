// The seam: one open connection, six operations, no target.

///|
/// One record as this package needs it, whatever it took to fetch.
///
/// A struct rather than the opaque accessor type the `js` FFI hands back,
/// because a record that has crossed the boundary is ordinary data and the
/// `Option` that says whether it was there at all belongs to `Conn::get`.
pub(all) struct Rec {
  data : Bytes
  /// `""` for absent, the spelling both boundaries use rather than a `null`.
  content_type : String
  modified : Int64
  is_dir : Bool
}

///|
/// A record's metadata, as `@sos` says it.
pub fn Rec::to_metadata(self : Rec) -> @sos.Metadata {
  if self.is_dir {
    @sos.Metadata::dir(last_modified=self.modified)
  } else {
    @sos.Metadata::file(
      self.data.length().to_int64(),
      content_type?=if self.content_type == "" {
        None
      } else {
        Some(self.content_type)
      },
      last_modified=self.modified,
    )
  }
}

///|
/// An open object store, reduced to what the semantics above it actually use.
///
/// `operation` is threaded through every method so a failure names the `@sos`
/// call the caller made -- "read", "create_dir" -- rather than the primitive it
/// happened to fail in. That is what makes one `SosError` type worth having.
///
/// Each implementation stamps `modified` itself, on `put`. The clock is the one
/// thing here that is genuinely the environment's, and threading it through the
/// seam would have bought a trait member and nothing else.
pub(open) trait Conn {
  /// The database name, for `StoreInfo`.
  fn name(Self) -> String

  /// One record, or `None` when the key is not there.
  async fn get(Self, String, operation~ : String) -> Rec? raise @sos.SosError

  /// Insert or replace one record, stamping it with now.
  async fn put(
    Self,
    String,
    Bytes,
    content_type~ : String,
    is_dir~ : Bool,
    operation~ : String,
  ) -> Unit raise @sos.SosError

  /// Delete one key. A key that is not there is not an error, here or in
  /// IndexedDB.
  async fn delete_one(Self, String, operation~ : String) -> Unit raise @sos.SosError

  /// Delete every key in `[low, high)`.
  async fn delete_range(Self, String, String, operation~ : String) -> Unit raise @sos.SosError

  /// Every record in `[low, high)`, metadata only, as the JSON rows
  /// `decode_rows` reads.
  ///
  /// Metadata only, and JSON rather than a typed array of structs, for two
  /// reasons. The object content never crosses this call, so a listing of a
  /// gigabyte of blobs costs nothing but their names. And one string is a shape
  /// a boundary cannot get subtly wrong -- parallel arrays or a struct per
  /// record would each be a second thing to keep in step with the JavaScript.
  async fn scan(Self, String, String, operation~ : String) -> String raise @sos.SosError
}
