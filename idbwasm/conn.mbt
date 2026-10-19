///|
/// An open connection, as a row number in JavaScript's handle table.
struct WasmConn {
  handle : Int32
  name : String
}

///|
/// Open, or create, `database` and use the object store `store` inside it.
pub async fn WasmConn::open(
  database~ : String = "sos",
  store~ : String = "objects",
) -> WasmConn raise @sos.SosError {
  let answer = ask(
    token => idb_open(database, store, token),
    operation="open",
    path="",
  )
  let handle = @string.parse_int(answer) catch {
    _ =>
      raise @sos.SosError::new(
        @sos.Unexpected,
        operation="open",
        message="could not open '\{database}': the boundary answered '\{answer}'",
      )
  }
  { handle, name: database, }
}

///|
/// A store over a freshly opened connection: the one call most callers want.
pub async fn open(
  database~ : String = "sos",
  store~ : String = "objects",
) -> @idbcore.IdbStore raise @sos.SosError {
  @idbcore.IdbStore::over(WasmConn::open(database~, store~))
}

///|
/// Close this connection and delete the whole database.
///
/// The reason this exists rather than being left to the caller's own FFI: a
/// database named for something that has been thrown away -- a session, a test
/// run -- should go when it does, and `indexedDB.deleteDatabase` blocks while a
/// connection is open, so the close and the delete belong in one call.
///
/// Closing first is allowed: the boundary keeps a closed handle's row precisely
/// so this can still name the database. Use `close` when the data outlives the
/// connection and this when it does not.
pub async fn WasmConn::destroy(self : WasmConn) -> Unit raise @sos.SosError {
  ask(token => idb_destroy(self.handle, token), operation="destroy", path="")
  |> ignore
}

///|
pub impl @idbcore.Conn for WasmConn with fn close(self) {
  ask(token => idb_close(self.handle, token), operation="close", path="")
  |> ignore
}

///|
pub impl @idbcore.Conn for WasmConn with fn name(self) {
  self.name
}

///|
pub impl @idbcore.Conn for WasmConn with fn get(self, key, operation~) {
  let body = ask(
    token => idb_get(self.handle, key, token),
    operation~,
    path=key,
  )
  let fields = match
    (@json.parse(body) catch {
      err =>
        raise @sos.SosError::new(
          @sos.Unexpected,
          operation~,
          path=key,
          message="could not read the record: \{err}",
        )
    }) {
    Object(fields) => fields
    _ =>
      raise @sos.SosError::new(
        @sos.Unexpected,
        operation~,
        path=key,
        message="the record was not an object",
      )
  }
  guard fields.get("found") is Some(True) else { return None }
  let data = match fields.get("b64") {
    Some(String(encoded)) =>
      @base64.decode(encoded) catch {
        _ =>
          raise @sos.SosError::new(
            @sos.Unexpected,
            operation~,
            path=key,
            message="the record's content was not base64",
          )
      }
    _ => b""
  }
  let content_type = match fields.get("c") {
    Some(String(value)) => value
    _ => ""
  }
  let modified = match fields.get("m") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  Some({ data, content_type, modified, is_dir: fields.get("d") is Some(True), })
}

///|
pub impl @idbcore.Conn for WasmConn with fn put(
  self,
  key,
  data,
  content_type~,
  is_dir~,
  operation~,
) {
  ask(
    token => {
      idb_put(
        self.handle,
        key,
        @base64.encode(data[:]),
        content_type,
        is_dir,
        token,
      )
    },
    operation~,
    path=key,
  )
  |> ignore
}

///|
pub impl @idbcore.Conn for WasmConn with fn delete_one(self, key, operation~) {
  ask(token => idb_delete_one(self.handle, key, token), operation~, path=key)
  |> ignore
}

///|
pub impl @idbcore.Conn for WasmConn with fn delete_range(
  self,
  low,
  high,
  operation~,
) {
  ask(
    token => idb_delete_range(self.handle, low, high, token),
    operation~,
    path=low,
  )
  |> ignore
}

///|
pub impl @idbcore.Conn for WasmConn with fn scan(self, low, high, operation~) {
  ask(token => idb_scan(self.handle, low, high, token), operation~, path=low)
}

///|
pub extend WasmConn with @idbcore.Conn::{
  name,
  scan,
  close,
  put,
  delete_one,
  get,
  delete_range,
}
