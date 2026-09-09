// The `js` way in: an `IDBRequest` becomes a `Promise`, and `Promise::wait()`
// turns it back into a value inside an async function.
//
// That is the whole of what this package is now. The semantics -- implicit
// directories, the key bound, the range delete, the ancestor walk -- live in
// `@sos/idbcore` and are shared with the `wasm-gc` boundary, which reaches the
// same database by an entirely different route. See `idbcore/moon.pkg` for why.

///|
/// An open connection, and the database name it was opened for.
struct IdbConn {
  db : Database
  name : String
}

///|
/// Open, or create, `database` and use the object store `store` inside it.
pub async fn IdbConn::open(
  database? : String = "sos",
  store? : String = "objects",
) -> IdbConn raise @sos.SosError {
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
/// A store over a freshly opened connection: the one call most callers want.
pub async fn open(
  database? : String = "sos",
  store? : String = "objects",
) -> @idbcore.IdbStore raise @sos.SosError {
  @idbcore.IdbStore::over(IdbConn::open(database~, store~))
}

///|
/// Whatever a boundary raised, as the one error type a caller catches.
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
pub impl @idbcore.Conn for IdbConn with fn name(self) {
  self.name
}

///|
pub impl @idbcore.Conn for IdbConn with fn close(self) {
  self.db.close()
}

///|
pub impl @idbcore.Conn for IdbConn with fn get(self, key, operation~) {
  let record = self.db.get(key).wait() catch {
      err => raise unexpected(err, operation~, path=key)
    }
  if record.is_missing() {
    None
  } else {
    Some({
      data: record.data(),
      content_type: record.content_type(),
      modified: record.modified().to_int64(),
      is_dir: record.is_dir(),
    })
  }
}

///|
pub impl @idbcore.Conn for IdbConn with fn put(
  self,
  key,
  data,
  content_type~,
  is_dir~,
  operation~,
) {
  self.db.put(key, data, content_type, now_ms(), is_dir).wait() catch {
    err => raise unexpected(err, operation~, path=key)
  }
}

///|
pub impl @idbcore.Conn for IdbConn with fn delete_one(self, key, operation~) {
  self.db.delete_one(key).wait() catch {
    err => raise unexpected(err, operation~, path=key)
  }
}

///|
pub impl @idbcore.Conn for IdbConn with fn delete_range(
  self,
  low,
  high,
  operation~,
) {
  self.db.delete_range(low, high).wait() catch {
    err => raise unexpected(err, operation~, path=low)
  }
}

///|
pub impl @idbcore.Conn for IdbConn with fn scan(self, low, high, operation~) {
  self.db.scan(low, high).wait() catch {
    err => raise unexpected(err, operation~, path=low)
  }
}
