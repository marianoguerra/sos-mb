// The IndexedDB surface, as narrowly as it can be drawn, in the one shape
// wasm-gc can draw it: every call takes a token and answers through an export.
//
// A handle is an `Int` and not an object. JavaScript keeps the open connection
// in a table of its own and MoonBit holds the row number, because a wasm-gc
// value cannot be a JavaScript object any more than a MoonBit closure can be a
// JavaScript function.
//
// Object content crosses as base64 in both directions. The resume door carries a
// `String` -- that is what an export can take -- so bytes have to be spelled in
// one, and base64 is the spelling that is lossless for all of them.

///|
/// Open, or create, `database` with a single object store `store` keyed on the
/// record's `path` field. Answers with the handle, in decimal.
extern "wasm" fn idb_open(
  database : String,
  store : String,
  token : Int32,
) -> Unit = "sosidb" "open"

///|
/// One record as a JSON document, or `{"found":false}`.
extern "wasm" fn idb_get(handle : Int32, key : String, token : Int32) -> Unit = "sosidb" "get"

///|
/// Insert or replace one record, stamped with the boundary's own clock.
extern "wasm" fn idb_put(
  handle : Int32,
  key : String,
  data : String,
  ctype : String,
  is_dir : Bool,
  token : Int32,
) -> Unit = "sosidb" "put"

///|
/// Delete one key. A key that is not there is not an error, here or in
/// IndexedDB.
extern "wasm" fn idb_delete_one(
  handle : Int32,
  key : String,
  token : Int32,
) -> Unit = "sosidb" "deleteOne"

///|
/// Delete every key in `[low, high)`.
extern "wasm" fn idb_delete_range(
  handle : Int32,
  low : String,
  high : String,
  token : Int32,
) -> Unit = "sosidb" "deleteRange"

///|
/// Every record in `[low, high)`, metadata only, as the JSON rows
/// `@idbcore.decode_rows` reads. The object content never crosses this call.
extern "wasm" fn idb_scan(
  handle : Int32,
  low : String,
  high : String,
  token : Int32,
) -> Unit = "sosidb" "scan"

///|
/// Hand the connection back, leaving the database where it is.
extern "wasm" fn idb_close(handle : Int32, token : Int32) -> Unit = "sosidb" "close"

///|
/// Close the handle and delete the whole database.
extern "wasm" fn idb_destroy(handle : Int32, token : Int32) -> Unit = "sosidb" "destroy"
