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
}

///|
fn MapConn::new() -> MapConn {
  { rows: Map([]), clock: 0L, }
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
pub impl @idbcore.Conn for MapConn with fn get(self, key, operation~) {
  ignore(operation)
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
  ignore(operation)
  self.clock = self.clock + 1L
  self.rows[key] = { data, content_type, modified: self.clock, is_dir, }
}

///|
pub impl @idbcore.Conn for MapConn with fn delete_one(self, key, operation~) {
  ignore(operation)
  self.rows.remove(key)
}

///|
pub impl @idbcore.Conn for MapConn with fn delete_range(
  self,
  low,
  high,
  operation~,
) {
  ignore(operation)
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
  ignore(operation)
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
