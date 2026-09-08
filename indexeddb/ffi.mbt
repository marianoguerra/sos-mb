// The IndexedDB surface, as narrowly as it can be drawn.
//
// Everything here returns a `@js_async.Promise`, which `Promise::wait()` turns
// back into an ordinary value inside an async function. That is the whole trick:
// the callback soup of `IDBRequest` stays on the JavaScript side of the boundary
// and never reaches MoonBit.
//
// `Bytes` is a `Uint8Array` on this backend, in both directions, so object
// content crosses the FFI with no encoding step.

///|
/// An open connection, plus the object store name it was opened for.
#external
priv type Database

///|
/// One record, or `undefined` when the key was not found.
///
/// Opaque with accessors rather than a struct, because `IDBObjectStore.get`
/// resolves `undefined` for a missing key and there is no safe way to send an
/// `Option` across the boundary. `is_missing` is the check that stands in for it.
#external
priv type Record

///|
/// Open (creating if needed) `database`, with a single object store `store`
/// keyed on the record's `path` field.
extern "js" fn open_db(
  database : String,
  store : String,
) -> @js_async.Promise[Database] =
  #|(database, store) => new Promise((resolve, reject) => {
  #|  const req = indexedDB.open(database, 1);
  #|  req.onupgradeneeded = () => {
  #|    const db = req.result;
  #|    if (!db.objectStoreNames.contains(store)) {
  #|      db.createObjectStore(store, { keyPath: "path" });
  #|    }
  #|  };
  #|  req.onsuccess = () => resolve({ db: req.result, store });
  #|  req.onerror = () => reject(req.error);
  #|})

///|
extern "js" fn Database::get(
  self : Database,
  key : String,
) -> @js_async.Promise[Record] =
  #|(h, key) => new Promise((resolve, reject) => {
  #|  const tx = h.db.transaction(h.store, "readonly");
  #|  const req = tx.objectStore(h.store).get(key);
  #|  req.onsuccess = () => resolve(req.result);
  #|  req.onerror = () => reject(req.error);
  #|})

///|
extern "js" fn Record::is_missing(self : Record) -> Bool =
  #|(r) => r === undefined || r === null

///|
extern "js" fn Record::data(self : Record) -> Bytes =
  #|(r) => r.data

///|
extern "js" fn Record::content_type(self : Record) -> String =
  #|(r) => r.ctype === undefined ? "" : r.ctype

///|
extern "js" fn Record::modified(self : Record) -> Double =
  #|(r) => r.mtime

///|
extern "js" fn Record::is_dir(self : Record) -> Bool =
  #|(r) => r.dir === true

///|
/// Insert or replace one record.
///
/// `ctype` is passed as `""` for absent rather than as `null`, so the FFI
/// signature stays a plain `String` in both directions.
extern "js" fn Database::put(
  self : Database,
  key : String,
  data : Bytes,
  ctype : String,
  modified : Double,
  is_dir : Bool,
) -> @js_async.Promise[Unit] =
  #|(h, key, data, ctype, mtime, dir) => new Promise((resolve, reject) => {
  #|  const tx = h.db.transaction(h.store, "readwrite");
  #|  const req = tx.objectStore(h.store).put({
  #|    path: key,
  #|    data: data,
  #|    ctype: ctype === "" ? undefined : ctype,
  #|    mtime: mtime,
  #|    dir: dir,
  #|  });
  #|  req.onsuccess = () => resolve();
  #|  req.onerror = () => reject(req.error);
  #|})

///|
/// Delete one key. Missing keys are not an error, here or in IndexedDB.
extern "js" fn Database::delete_one(
  self : Database,
  key : String,
) -> @js_async.Promise[Unit] =
  #|(h, key) => new Promise((resolve, reject) => {
  #|  const tx = h.db.transaction(h.store, "readwrite");
  #|  const req = tx.objectStore(h.store).delete(key);
  #|  req.onsuccess = () => resolve();
  #|  req.onerror = () => reject(req.error);
  #|})

///|
/// Delete every key in `[low, high)`.
extern "js" fn Database::delete_range(
  self : Database,
  low : String,
  high : String,
) -> @js_async.Promise[Unit] =
  #|(h, low, high) => new Promise((resolve, reject) => {
  #|  const tx = h.db.transaction(h.store, "readwrite");
  #|  const range = IDBKeyRange.bound(low, high, false, true);
  #|  const req = tx.objectStore(h.store).delete(range);
  #|  req.onsuccess = () => resolve();
  #|  req.onerror = () => reject(req.error);
  #|})

///|
/// Every record in `[low, high)`, as metadata only, JSON-encoded.
///
/// Metadata only, and JSON rather than a typed array of structs, for two
/// reasons. The object content never crosses this call, so a listing of a
/// gigabyte of blobs costs nothing but their names. And one string is a shape
/// the FFI cannot get subtly wrong -- parallel arrays or a struct-per-record
/// would each be a second thing to keep in step with the JavaScript.
extern "js" fn Database::scan(
  self : Database,
  low : String,
  high : String,
) -> @js_async.Promise[String] =
  #|(h, low, high) => new Promise((resolve, reject) => {
  #|  const tx = h.db.transaction(h.store, "readonly");
  #|  const range = IDBKeyRange.bound(low, high, false, true);
  #|  const req = tx.objectStore(h.store).openCursor(range);
  #|  const rows = [];
  #|  req.onsuccess = () => {
  #|    const cursor = req.result;
  #|    if (!cursor) { resolve(JSON.stringify(rows)); return; }
  #|    const v = cursor.value;
  #|    rows.push({
  #|      p: v.path,
  #|      n: v.data ? v.data.length : 0,
  #|      m: v.mtime,
  #|      c: v.ctype === undefined ? null : v.ctype,
  #|      d: v.dir === true,
  #|    });
  #|    cursor.continue();
  #|  };
  #|  req.onerror = () => reject(req.error);
  #|})

///|
/// Milliseconds since the epoch, from the page's clock.
extern "js" fn now_ms() -> Double =
  #|() => Date.now()

///|
/// Is IndexedDB reachable at all?
///
/// A worker without it, or a browser in a mode that refuses storage, should fail
/// at `open` with something a caller can read rather than at the first `put`
/// with a `ReferenceError`.
extern "js" fn has_indexeddb() -> Bool =
  #|() => typeof indexedDB !== "undefined" && indexedDB !== null
