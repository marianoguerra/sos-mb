///|
/// What went wrong, in terms a caller can branch on.
///
/// The set is OpenDAL's, minus the kinds only a network backend can produce,
/// plus two this library needs and OpenDAL folds into `Unexpected`:
///
/// - `InvalidPath`, because a rejected path is the caller's bug, and a caller
///   that cannot tell it from an I/O failure will retry it forever.
/// - `DirectoryNotEmpty`, because the only other honest answer is `Unexpected`,
///   and then a caller cannot tell "pass `recursive`" from "something broke".
pub(all) enum ErrorKind {
  /// Nothing at that path.
  NotFound
  /// Something is already there, and the caller asked not to overwrite it.
  AlreadyExists
  PermissionDenied
  /// A file operation was aimed at a directory.
  IsADirectory
  /// A directory operation was aimed at a file.
  NotADirectory
  /// A directory still has children, and `recursive` was not set.
  DirectoryNotEmpty
  /// The path could never name anything in a store. See `validate`.
  InvalidPath
  /// The backend does not do this. Raised by `Operator` from `Capability`,
  /// before the call reaches the store.
  Unsupported
  ConfigInvalid
  /// A ranged read started past the end of the object.
  RangeNotSatisfied
  /// Everything else, including whatever a backend's own dependency raised.
  Unexpected
} derive(Eq, Debug)

///|
/// Written by hand rather than derived, because these names end up in the
/// message a person reads when a store call fails.
pub impl Show for ErrorKind with fn output(self, logger) {
  logger.write_string(
    match self {
      NotFound => "not found"
      AlreadyExists => "already exists"
      PermissionDenied => "permission denied"
      IsADirectory => "is a directory"
      NotADirectory => "not a directory"
      DirectoryNotEmpty => "directory not empty"
      InvalidPath => "invalid path"
      Unsupported => "unsupported"
      ConfigInvalid => "invalid config"
      RangeNotSatisfied => "range not satisfied"
      Unexpected => "unexpected"
    },
  )
}

///|
/// Every failure this library raises.
///
/// One error type, not one per backend: the point of the `Store` seam is that a
/// caller's `catch` sees the same thing whether the bytes came from a `Map`, a
/// disk or a browser database. A backend that lets `@os_error.OSError` or a JS
/// error escape has broken the abstraction, so each translates at its boundary.
pub(all) suberror SosError {
  SosError(
    kind~ : ErrorKind,
    /// The operation that failed: "read", "write", "list", ...
    operation~ : String,
    /// The store path it was on. Empty when there is none.
    path~ : String,
    /// One sentence for a person. May be empty.
    message~ : String
  )
}

///|
pub fn SosError::new(
  kind : ErrorKind,
  operation~ : String,
  path? : String = "",
  message? : String = "",
) -> SosError {
  SosError(kind~, operation~, path~, message~)
}

///|
pub fn SosError::kind(self : SosError) -> ErrorKind {
  let SosError(kind~, ..) = self
  kind
}

///|
pub fn SosError::operation(self : SosError) -> String {
  let SosError(operation~, ..) = self
  operation
}

///|
pub fn SosError::path(self : SosError) -> String {
  let SosError(path~, ..) = self
  path
}

///|
pub fn SosError::message(self : SosError) -> String {
  let SosError(message~, ..) = self
  message
}

///|
/// True when the store said "there is nothing here".
///
/// The one kind callers branch on often enough to deserve a name; the rest go
/// through `kind()`.
pub fn SosError::is_not_found(self : SosError) -> Bool {
  self.kind() is NotFound
}

///|
pub impl Show for SosError with fn output(self, logger) {
  let SosError(kind~, operation~, path~, message~) = self
  logger.write_string("\{kind} in \{operation}")
  if path != "" {
    logger.write_string(" at '\{path}'")
  }
  if message != "" {
    logger.write_string(": \{message}")
  }
}
