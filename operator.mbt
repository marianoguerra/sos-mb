///|
/// The front door.
///
/// Holds a `&Store` and does three things the trait deliberately does not:
/// normalises and validates every path, turns labelled optional arguments into
/// the option structs, and refuses up front whatever `Capability` says the
/// backend cannot do. A backend author writes `Store`; everyone else writes
/// this.
struct Operator {
  store : &Store
  info : StoreInfo
}

///|
pub fn Operator::new(store : &Store) -> Operator {
  { store, info: store.info(), }
}

///|
pub fn Operator::info(self : Operator) -> StoreInfo {
  self.info
}

///|
pub fn Operator::capability(self : Operator) -> Capability {
  self.info.capability
}

///|
/// The store underneath, for a caller that needs the raw seam.
pub fn Operator::store(self : Operator) -> &Store {
  self.store
}

///|
/// Raise `Unsupported` unless the backend declared it can do this.
///
/// Checked here rather than in each backend so an unsupported option fails
/// naming the operation the caller asked for, instead of somewhere inside a
/// backend that had to invent an error for a case it does not implement.
fn Operator::require(
  self : Operator,
  supported : Bool,
  operation~ : String,
  path~ : String,
  what~ : String,
) -> Unit raise SosError {
  guard supported else {
    raise SosError::new(
      Unsupported,
      operation~,
      path~,
      message="the \{self.info.scheme} store does not support \{what}",
    )
  }
}

///|
pub async fn Operator::read(
  self : Operator,
  path : String,
  range? : Range,
) -> Bytes raise SosError {
  let path = validate_file(path, operation="read")
  let cap = self.info.capability
  self.require(cap.read, operation="read", path~, what="read")
  if range is Some(_) {
    self.require(
      cap.read_with_range,
      operation="read",
      path~,
      what="ranged reads",
    )
  }
  self.store.read(path, { range, })
}

///|
/// `read`, decoded as UTF-8.
pub async fn Operator::read_text(
  self : Operator,
  path : String,
  range? : Range,
) -> String raise SosError {
  let bytes = self.read(path, range?)
  @utf8.decode(bytes) catch {
    _ =>
      raise SosError::new(
        Unexpected,
        operation="read_text",
        path~,
        message="content is not valid UTF-8",
      )
  }
}

///|
pub async fn Operator::write(
  self : Operator,
  path : String,
  content : Bytes,
  content_type? : String,
  append? : Bool = false,
  if_not_exists? : Bool = false,
) -> Unit raise SosError {
  let path = validate_file(path, operation="write")
  let cap = self.info.capability
  self.require(cap.write, operation="write", path~, what="write")
  if content_type is Some(_) {
    self.require(
      cap.write_with_content_type,
      operation="write",
      path~,
      what="content types",
    )
  }
  if append {
    self.require(cap.write_can_append, operation="write", path~, what="append")
  }
  if if_not_exists {
    self.require(
      cap.write_with_if_not_exists,
      operation="write",
      path~,
      what="conditional create",
    )
  }
  self.store.write(path, content, { content_type, append, if_not_exists, })
}

///|
/// `write`, encoding the string as UTF-8.
pub async fn Operator::write_text(
  self : Operator,
  path : String,
  content : String,
  content_type? : String,
  append? : Bool = false,
  if_not_exists? : Bool = false,
) -> Unit raise SosError {
  self.write(
    path,
    @utf8.encode(content),
    content_type?,
    append~,
    if_not_exists~,
  )
}

///|
pub async fn Operator::stat(
  self : Operator,
  path : String,
) -> Metadata raise SosError {
  let path = validate(path, operation="stat")
  self.require(self.info.capability.stat, operation="stat", path~, what="stat")
  self.store.stat(path)
}

///|
/// Does it resolve? `stat` reduced to the question most callers were asking.
pub async fn Operator::exists(
  self : Operator,
  path : String,
) -> Bool raise SosError {
  try {
    self.stat(path) |> ignore
    true
  } catch {
    err => if err.is_not_found() { false } else { raise err }
  }
}

///|
pub async fn Operator::list(
  self : Operator,
  path : String,
  recursive? : Bool = false,
  limit? : Int,
  start_after? : String,
) -> Array[Entry] raise SosError {
  let path = validate_dir(path, operation="list")
  let cap = self.info.capability
  self.require(cap.list, operation="list", path~, what="list")
  if recursive {
    self.require(
      cap.list_with_recursive,
      operation="list",
      path~,
      what="recursive listing",
    )
  }
  if limit is Some(_) {
    self.require(cap.list_with_limit, operation="list", path~, what="limit")
  }
  if start_after is Some(_) {
    self.require(
      cap.list_with_start_after,
      operation="list",
      path~,
      what="start_after",
    )
  }
  self.store.list(path, { recursive, limit, start_after, })
}

///|
pub async fn Operator::delete(
  self : Operator,
  path : String,
  recursive? : Bool = false,
) -> Unit raise SosError {
  let path = validate(path, operation="delete")
  let cap = self.info.capability
  self.require(cap.delete, operation="delete", path~, what="delete")
  if recursive {
    self.require(
      cap.delete_with_recursive,
      operation="delete",
      path~,
      what="recursive delete",
    )
  }
  self.store.delete(path, { recursive, })
}

///|
pub async fn Operator::create_dir(
  self : Operator,
  path : String,
) -> Unit raise SosError {
  let path = validate_dir(path, operation="create_dir")
  self.require(
    self.info.capability.create_dir,
    operation="create_dir",
    path~,
    what="create_dir",
  )
  self.store.create_dir(path)
}

///|
pub async fn Operator::copy(
  self : Operator,
  from : String,
  to : String,
) -> Unit raise SosError {
  let from = validate_file(from, operation="copy")
  let to = validate_file(to, operation="copy")
  self.require(
    self.info.capability.copy,
    operation="copy",
    path=from,
    what="copy",
  )
  self.store.copy(from, to)
}

///|
pub async fn Operator::rename(
  self : Operator,
  from : String,
  to : String,
) -> Unit raise SosError {
  let from = validate_file(from, operation="rename")
  let to = validate_file(to, operation="rename")
  self.require(
    self.info.capability.rename,
    operation="rename",
    path=from,
    what="rename",
  )
  self.store.rename(from, to)
}
