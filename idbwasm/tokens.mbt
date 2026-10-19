// The token registry, and the two doors JavaScript comes back through.

///|
/// What a call is waiting for: the body it asked for, or a sentence.
priv enum Answer {
  Ok(String)
  Failed(String)
}

///|
/// Calls in flight, by token.
let inflight : Map[Int32, (Answer) -> Unit] = Map([])

///|
let next_token : Ref[Int32] = { val: 0, }

///|
/// Register a continuation and answer with the token to hand JavaScript.
fn claim(k : (Answer) -> Unit) -> Int32 {
  next_token.val = next_token.val + 1
  let token = next_token.val
  inflight[token] = k
  token
}

///|
/// The call this token stands for succeeded, with `body`.
///
/// Called from an export the linking executable declares. A token that is not
/// in flight is ignored rather than fatal: a boundary that answered twice
/// should not take the tab down, and `park` below already guarantees only the
/// first answer is delivered.
pub fn reply(token : Int32, body : String) -> Unit {
  match inflight.get(token) {
    Some(k) => {
      inflight.remove(token)
      k(Ok(body))
    }
    None => ()
  }
}

///|
/// The call this token stands for failed, for the reason `why` gives.
pub fn fail(token : Int32, why : String) -> Unit {
  match inflight.get(token) {
    Some(k) => {
      inflight.remove(token)
      k(Failed(why))
    }
    None => ()
  }
}

///|
/// How many calls are waiting. For a harness, and for a leak to be visible.
pub fn pending() -> Int32 {
  inflight.length()
}

///|
/// Start an asynchronous computation from a synchronous caller.
///
/// The compiler's own driver: it runs until the work finishes or parks and
/// returns either way. This is what lets a page with no event loop -- wasm-gc
/// has none -- start a store call that will not finish for a while.
pub fn run_async(work : async () -> Unit noraise) -> Unit = "%async.run"

///|
/// Park the current run and hand its continuation to `register`.
///
/// Never called directly: `park` wraps it, because a boundary that answers on
/// the spot must not wake a run that has not suspended yet.
///
/// TWO callbacks, resume and fail, which is the shape
/// `moonbitlang/async`'s own `async_suspend` declares. The one-callback
/// spelling type-checks and then crashes moonc in code generation
/// (`Invalid_argument("Moonc.Basic_lst.fold_right2")`, v0.10.12+1634b282e) --
/// an arity mismatch reaching the backend, on every target. Nothing here
/// raises, so the fail half is ignored and a failure travels in the `Answer`
/// this returns; it is declared only because the intrinsic wants it.
async fn[T] suspend(
  register : ((T) -> Unit, (Error) -> Unit) -> Unit,
) -> T noraise = "%async.suspend"

///|
/// Make one call, and give the answer back -- now if it is ready now, later if
/// it is not.
///
/// The buffer is the subtle part. `suspend` hands the parked run's continuation
/// to `register`, so a `go` that answered INSIDE `register` would be resuming a
/// run that has not parked. The answer is caught first, and the run only
/// suspends when there is nothing to give it. Nothing here answers on the spot
/// today, and a boundary that starts to should not have to know that.
async fn park(go : ((Answer) -> Unit) -> Unit) -> Answer noraise {
  let answered : Ref[Answer?] = { val: None, }
  let waking : Ref[((Answer) -> Unit)?] = { val: None, }
  let settled : Ref[Bool] = { val: false, }
  go(answer => {
    // Exactly once. A boundary that replied twice would otherwise wake a run
    // that is already somewhere else.
    if settled.val {
      return
    }
    settled.val = true
    match waking.val {
      Some(k) => k(answer)
      None => answered.val = Some(answer)
    }
  })
  match answered.val {
    Some(answer) => answer
    None => suspend((k, _fail) => waking.val = Some(k))
  }
}

///|
/// Ask JavaScript to do one thing, and wait for the body it answers with.
///
/// `go` receives the token to pass across; whatever it starts must eventually
/// reach `reply` or `fail` with that token, or the call never returns.
async fn ask(
  go : (Int32) -> Unit,
  operation~ : String,
  path~ : String,
) -> String raise @sos.SosError {
  let answer = park(k => go(claim(k)))
  match answer {
    Ok(body) => body
    Failed(why) =>
      raise @sos.SosError::new(@sos.Unexpected, operation~, path~, message=why)
  }
}
