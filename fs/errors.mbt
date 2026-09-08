// Translating the operating system's answers into this library's.
//
// The rule the `Store` trait states: nothing from a backend's own dependencies
// escapes. Everything `moonbitlang/async/fs` raises stops here.

///|
/// Turn whatever `@fs` raised into a `SosError`.
///
/// `@os_error` exposes predicates for ENOENT, EEXIST, EACCES and ENOTDIR and no
/// others -- in particular there is no `is_EISDIR` and no `is_ENOTEMPTY`. Those
/// two matter to this library, so rather than guess at errno numbers that differ
/// per platform, the operations that can hit them look at the path before acting
/// (see `delete` and `read`) and this function never has to produce them.
fn translate(err : Error, operation~ : String, path~ : String) -> @sos.SosError {
  match err {
    @os_error.OSError(_) as os => {
      let kind = if os.is_ENOENT() {
        @sos.NotFound
      } else if os.is_EEXIST() {
        @sos.AlreadyExists
      } else if os.is_EACCES() {
        @sos.PermissionDenied
      } else if os.is_ENOTDIR() {
        @sos.NotADirectory
      } else {
        @sos.Unexpected
      }
      @sos.SosError::new(kind, operation~, path~, message=os.to_string())
    }
    // Something below already spoke this language; do not wrap it twice.
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
