// Running the conformance suite where IndexedDB actually exists.
//
// Not a `moon test`: node has no `indexedDB`, so the only honest place to run
// this backend is a browser. `moon build --target js -p
// marianoguerra/sos/indexeddb/harness` produces the module `index.html` loads,
// and the page shows what came back.
//
// The suite itself is the same one the memory and filesystem backends run. That
// is the point: nothing here is an IndexedDB-flavoured version of the checks.

///|
/// Show the outcome on the page, and in the console for a headless run.
extern "js" fn publish(summary : String, ok : Bool) -> Unit =
  #|(summary, ok) => {
  #|  console.log(summary);
  #|  globalThis.__sos_result = { summary, ok };
  #|  const el = globalThis.document && document.getElementById("out");
  #|  if (el) {
  #|    el.textContent = summary;
  #|    el.className = ok ? "ok" : "fail";
  #|  }
  #|}

///|
/// `close`, end to end: it must release the connection, tolerate being called
/// twice, and leave the store unusable afterwards.
///
/// Nothing under `moon test` can check this half -- node has no `indexedDB`, so
/// the closed `IDBDatabase` that throws `InvalidStateError` out of
/// `transaction()` only exists in a browser.
async fn close_check() -> String noraise {
  let store = @indexeddb.open(database="sos-close-\{@async.now()}") catch {
    err => return "could not open: \{err}"
  }
  try {
    // Twice, because a release a caller cannot repeat is a release a caller has
    // to keep track of.
    store.close()
    store.close()
  } catch {
    err => return "close raised: \{err}"
  }
  try {
    @sos.Operator::new(store).write("after.txt", b"x")
    "a write after close succeeded"
  } catch {
    _ => "ok"
  }
}

///|
async fn main {
  let outcome = try {
    // A fresh database per run, so a previous run cannot make this one pass.
    let store = @indexeddb.open(database="sos-conformance-\{@async.now()}")
    let report = @testing.check(store)
    let closing = close_check()
    ("\{report}\nclose: \{closing}", report.is_ok() && closing == "ok")
  } catch {
    err => ("the harness could not run: \{err}", false)
  }
  let (summary, ok) = outcome
  publish((if ok { "PASS\n" } else { "FAIL\n" }) + summary, ok)
}
