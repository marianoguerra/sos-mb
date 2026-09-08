// Running the suite where there is no scheduler.
//
// `%async.run` is the language intrinsic that runs an async computation on the
// current stack until it completes or suspends. `moonbitlang/async` is a
// *scheduler* built on top of it, not the thing that makes `async` work -- so a
// store that never actually waits needs neither an event loop nor a dependency,
// and can be tested on every backend including wasm-gc, where the event loop is
// unimplemented.
//
// The other reason this exists: moon's generated test driver only supplies
// `run_async_tests` when the package imports `moonbitlang/async`. Without it an
// `async test` compiles, never runs, and passes. A silent no-op is worse than a
// build error, so packages that have no scheduler use these instead.

///|
fn run_to_completion(work : async () -> Unit noraise) -> Unit = "%async.run"

///|
/// Run the whole suite here, on this stack, with no scheduler.
///
/// Valid for a store that never suspends -- `MemoryStore` is the one that ships.
/// If the store does suspend, this raises rather than returning: the alternative
/// is a half-finished run reported as a pass.
pub fn run_sync(
  store : &@sos.Store,
  prefix? : String = "sos-conformance/",
) -> Unit raise {
  let caught : Ref[Error?] = { val: None, }
  let finished : Ref[Bool] = { val: false, }
  run_to_completion(async fn() noraise {
    run(store, prefix~) catch {
      err => caught.val = Some(err)
    }
    finished.val = true
  })
  guard finished.val else {
    raise Failed(
      "the store suspended; run_sync only drives stores that never wait",
    )
  }
  match caught.val {
    Some(err) => raise err
    None => ()
  }
}

///|
/// `check`, driven the same way.
pub fn check_sync(
  store : &@sos.Store,
  prefix? : String = "sos-conformance/",
) -> Report raise {
  let report : Ref[Report?] = { val: None, }
  run_to_completion(async fn() noraise {
    report.val = Some(check(store, prefix~))
  })
  match report.val {
    Some(value) => value
    None =>
      raise Failed(
        "the store suspended; check_sync only drives stores that never wait",
      )
  }
}
