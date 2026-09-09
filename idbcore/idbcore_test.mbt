// The semantics, against a connection made of a `Map`.
//
// This is what the extraction bought. Before it, everything in `store.mbt` was
// reachable only from a browser: implicit directories, the range delete, the
// ancestor walk in `create_dir`, `stat` on a directory nobody stored a marker
// for. Now the same code runs the shared conformance suite under `moon test` on
// every backend, and the two real connections are left with six methods each
// that do nothing but talk to IndexedDB.
//
// Plain `test` driven by `@testing.run_sync`, not `async test`: this package
// imports no scheduler, and `MapConn` never suspends. See `testing/drive.mbt`.

///|
/// A `Conn` over a `Map`, standing in for an open object store.
///
/// It answers `scan` by building the same JSON rows the two real boundaries
/// build, rather than by handing back entries directly -- so `decode_rows` is
/// on the path these tests cover, and a row shape that drifted would fail here
/// rather than in a browser.
struct MapConn {
  rows : Map[String, @idbcore.Rec]
  mut clock : Int64
  mut closed : Bool
}

///|
fn MapConn::new() -> MapConn {
  { rows: Map([]), clock: 0L, closed: false, }
}

///|
/// Refuse an operation on a connection that has been handed back.
///
/// A stub that kept answering after `close` would be the one place this
/// contract is not enforced, and the only place it is cheap to test: on `js` a
/// closed `IDBDatabase` throws `InvalidStateError` out of `transaction()`, and
/// on `wasm-gc` `loader.mjs` rejects a closed row by hand. Both raise. So does
/// this.
fn MapConn::live(
  self : MapConn,
  operation~ : String,
) -> Unit raise @sos.SosError {
  guard !self.closed else {
    raise @sos.SosError::new(
      @sos.Unexpected,
      operation~,
      message="the connection is closed",
    )
  }
}

///|
/// Is `key` in `[low, high)`, in the order IndexedDB puts keys in?
///
/// `@sos.path_compare`, never `<`. MoonBit's `Compare for String` is
/// length-first -- `"b/" < "a.txt"` -- which is a fine total order and not the
/// one a key range means. A stub that used `<` would answer `scan` with the
/// wrong rows and quietly disagree with both real boundaries.
fn in_range(key : String, low : String, high : String) -> Bool {
  @sos.path_compare(key, low) >= 0 && @sos.path_compare(key, high) < 0
}

///|
pub impl @idbcore.Conn for MapConn with fn name(_) {
  "map"
}

///|
/// Nothing to hand back -- but recorded, so a test can see that closing the
/// store reached the connection instead of stopping at `IdbStore`.
pub impl @idbcore.Conn for MapConn with fn close(self) {
  self.closed = true
}

///|
pub impl @idbcore.Conn for MapConn with fn get(self, key, operation~) {
  self.live(operation~)
  self.rows.get(key)
}

///|
pub impl @idbcore.Conn for MapConn with fn put(
  self,
  key,
  data,
  content_type~,
  is_dir~,
  operation~,
) {
  self.live(operation~)
  self.clock = self.clock + 1L
  self.rows[key] = { data, content_type, modified: self.clock, is_dir, }
}

///|
pub impl @idbcore.Conn for MapConn with fn delete_one(self, key, operation~) {
  self.live(operation~)
  self.rows.remove(key)
}

///|
pub impl @idbcore.Conn for MapConn with fn delete_range(
  self,
  low,
  high,
  operation~,
) {
  self.live(operation~)
  let doomed : Array[String] = []
  for key, _ in self.rows {
    if in_range(key, low, high) {
      doomed.push(key)
    }
  }
  for key in doomed {
    self.rows.remove(key)
  }
}

///|
pub impl @idbcore.Conn for MapConn with fn scan(self, low, high, operation~) {
  self.live(operation~)
  let out : Array[Json] = []
  for key, rec in self.rows {
    if in_range(key, low, high) {
      out.push(
        Json::object({
          "p": Json::string(key),
          "n": Json::number(rec.data.length().to_double()),
          "m": Json::number(rec.modified.to_double()),
          "c": if rec.content_type == "" {
            Json::null()
          } else {
            Json::string(rec.content_type)
          },
          "d": Json::boolean(rec.is_dir),
        }),
      )
    }
  }
  Json::array(out).stringify()
}

///|
fn store() -> @idbcore.IdbStore {
  @idbcore.IdbStore::over(MapConn::new())
}

///|
test "the IndexedDB semantics pass the conformance suite" {
  @testing.run_sync(store())
}

///|
test "every check passes or is skipped, and only append is skipped" {
  let report = @testing.check_sync(store())
  assert_eq(report.failures().length(), 0)
  // `write_can_append` is the one capability this backend declares false, for
  // the reason `store.mbt` gives, and the suite asserts the inverse of every
  // false flag. So exactly the append checks are skipped -- if this number
  // moves, a capability was turned off without meaning to.
  assert_true(report.skipped() > 0)
  assert_true(report.passed() > 20)
}

///|
test "the suite leaves nothing behind" {
  let conn = MapConn::new()
  @testing.run_sync(@idbcore.IdbStore::over(conn))
  assert_eq(conn.rows.length(), 0)
}

///|
test "the key bound stops at the prefix" {
  // The whole soundness argument for `list` and the recursive `delete`: nothing
  // outside `[prefix, prefix + U+FFFF)` is read, and `@sos.validate` rejects
  // `U+FFFF` in a path so nothing can climb over it.
  // Compared with `@sos.path_compare`, never with `<`: MoonBit's
  // `Compare for String` is length-first, and the bound is only a bound in the
  // code-unit order IndexedDB and `path_compare` share.
  assert_eq(@idbcore.upper_bound("notes/"), "notes/\u{FFFF}")
  assert_true(
    @sos.path_compare(@idbcore.upper_bound("notes/"), "notes/zzz") > 0,
  )
  assert_true(@sos.path_compare(@idbcore.upper_bound("notes/"), "notesx") < 0)
}

///|
test "a row the boundary garbled is dropped, not fatal" {
  // A record with no `p` is a record this package cannot name. Skipping it
  // keeps one bad row from failing a whole listing.
  let rows =
    #|[{"p":"a.txt","n":3,"m":1,"c":null,"d":false},{"n":9},{"p":"d/","d":true,"m":2}]
  let entries = @idbcore.decode_rows(rows, "", operation="list")
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].path, "a.txt")
  assert_eq(entries[0].metadata.content_length, 3L)
  assert_true(entries[1].metadata.is_dir())
}

///|
test "a scan that is not JSON names the operation the caller made" {
  try
    @idbcore.decode_rows("not json", "notes/", operation="list") |> ignore
  catch {
    @sos.SosError(_) as err => {
      assert_eq(err.operation(), "list")
      assert_eq(err.path(), "notes/")
      assert_eq(err.kind(), @sos.Unexpected)
    }
  } noraise {
    _ => fail("expected a scan that is not JSON to raise")
  }
}

///|
/// Run an async body here, on this stack, and hand back whatever it raised.
///
/// `MapConn` never suspends, so no scheduler is needed -- the same reason the
/// suite runs through `@testing.run_sync`. See `testing/drive.mbt`.
fn drive(work : async () -> Unit noraise) -> Unit = "%async.run"

///|
fn attempt(work : async () -> Unit) -> Error? {
  let caught : Ref[Error?] = { val: None, }
  drive(async fn() noraise { work() catch { err => caught.val = Some(err) } })
  caught.val
}

///|
/// Closing the store must reach the connection.
///
/// The whole point of `IdbStore::close`: `@indexeddb.open` and `@idbwasm.open`
/// both answer with a store and keep the `Conn` to themselves, so a caller who
/// took the one-call opener has nothing else to close. A program that swaps one
/// store for another at runtime drops a live database connection on every
/// switch without it.
test "closing the store closes the connection underneath" {
  let conn = MapConn::new()
  let store = @idbcore.IdbStore::over(conn)
  assert_false(conn.closed)
  assert_true(attempt(async fn() { store.close() }) is None)
  assert_true(conn.closed)
}

///|
test "close is idempotent" {
  let conn = MapConn::new()
  let store = @idbcore.IdbStore::over(conn)
  assert_true(attempt(async fn() { store.close() }) is None)
  assert_true(attempt(async fn() { store.close() }) is None)
  assert_true(conn.closed)
}

///|
/// After close, an operation must fail rather than quietly appear to work.
///
/// Both real boundaries do this -- a closed `IDBDatabase` throws
/// `InvalidStateError` out of `transaction()` on `js`, and `loader.mjs` rejects
/// a closed row by hand on `wasm-gc`. This is where it is cheap to assert.
test "a store used after close fails" {
  let conn = MapConn::new()
  let store = @idbcore.IdbStore::over(conn)
  let op = @sos.Operator::new(store)
  assert_true(attempt(async fn() { store.close() }) is None)
  let caught = attempt(async fn() { op.write("after.txt", b"x") })
  let kind = match caught {
    Some(@sos.SosError(kind~, ..)) => Some(kind)
    _ => None
  }
  assert_eq(kind, Some(@sos.Unexpected))
}
