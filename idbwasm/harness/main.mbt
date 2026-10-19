// Running the conformance suite where IndexedDB actually exists, on wasm-gc.
//
// Not a `moon test`: node has no `indexedDB`, and this store genuinely
// suspends, so `@testing.run_sync` would refuse it even where there were one.
// The suite is the same one the memory and filesystem backends run under
// `moon test`, and the same one `indexeddb/harness` runs on the `js` backend --
// which is the point: nothing here is an IndexedDB-flavoured version of the
// checks, and the two boundaries are held to one standard.
//
// This file is also the reference for embedding `@sos/idbwasm`. A host needs
// exactly three things and they are all visible here: the two exports below,
// the `sosidb` import object in `loader.mjs`, and a `run_async` to start from.

///|
/// Show the outcome on the page, and in the console for a headless run.
extern "wasm" fn publish(summary : String, ok : Bool) -> Unit = "harness" "publish"

///|
/// Milliseconds since the epoch, for a database name no previous run used.
extern "wasm" fn now_ms() -> Double = "harness" "now"

///|
/// A call this page started has succeeded.
pub fn on_sos_reply(token : Int32, body : String) -> Unit {
  @idbwasm.reply(token, body)
}

///|
/// A call this page started has failed.
pub fn on_sos_error(token : Int32, why : String) -> Unit {
  @idbwasm.fail(token, why)
}

///|
/// `close`, end to end, and the order that matters: closing first must not
/// leave the database behind, because `destroy` still has to be able to name it.
///
/// Nothing under `moon test` reaches this. It is the only check that the
/// handle-table row survives `close` and that `destroy` finds it.
async fn close_check() -> String noraise {
  let conn = @idbwasm.WasmConn::open(
    database="sos-close-\{now_ms().to_int64()}",
  ) catch {
    err => return "could not open: \{err}"
  }
  let store = @idbcore.IdbStore::over(conn)
  try {
    // Twice, because a release a caller cannot repeat is a release a caller has
    // to keep track of.
    store.close()
    store.close()
  } catch {
    err => return "close raised: \{err}"
  }
  let after = try {
    @sos.Operator::new(store).write("after.txt", b"x")
    "a write after close succeeded"
  } catch {
    _ => "ok"
  }
  conn.destroy() catch {
    err => return "destroy after close raised: \{err}"
  }
  after
}

///|
/// Start the run and return.
///
/// `run_async` drives the suite on this stack until the first call parks, and
/// then returns -- there is no event loop on wasm-gc to hand control to. What
/// resumes it is `on_sos_reply` above, called by JavaScript when a Promise it
/// owns settles. So the interesting thing about this function is that it
/// finishes long before the suite does.
fn main {
  @idbwasm.run_async(async fn() noraise {
    let outcome = try {
      // A fresh database per run, so a previous run cannot make this one pass.
      let name = "sos-conformance-\{now_ms().to_int64()}"
      let conn = @idbwasm.WasmConn::open(database=name)
      let report = @testing.check(@idbcore.IdbStore::over(conn))
      let closing = close_check()
      let summary = (
        "\{report}\nclose: \{closing}",
        report.is_ok() && closing == "ok",
      )
      // And gone again, so a browser does not accumulate one database per run.
      // This is `destroy`'s own test as well: nothing else calls it.
      conn.destroy()
      summary
    } catch {
      err => ("the harness could not run: \{err}", false)
    }
    let (summary, ok) = outcome
    publish((if ok { "PASS\n" } else { "FAIL\n" }) + summary, ok)
  })
}
