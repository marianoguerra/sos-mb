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
async fn main {
  let outcome = try {
    // A fresh database per run, so a previous run cannot make this one pass.
    let store = @indexeddb.open(database="sos-conformance-\{@async.now()}")
    let report = @testing.check(store)
    (report.to_string(), report.is_ok())
  } catch {
    err => ("the harness could not run: \{err}", false)
  }
  let (summary, ok) = outcome
  publish((if ok { "PASS\n" } else { "FAIL\n" }) + summary, ok)
}
