// Assertions that a suite can catch.
//
// Not `assert_eq`: those raise into moon's test driver, which is not where a
// check's result goes. A check has to be able to fail, be recorded, and let the
// run continue.

///|
priv suberror Failed {
  Failed(String)
}

///|
/// Run `work` and return whatever it raised.
async fn attempt(work : async () -> Unit) -> Error? noraise {
  try {
    work()
    None
  } catch {
    err => Some(err)
  }
}

///|
fn expect(condition : Bool, what : String) -> Unit raise Failed {
  guard condition else { raise Failed(what) }
}

///|
fn expect_bytes(got : Bytes, want : Bytes, what : String) -> Unit raise Failed {
  guard got == want else {
    raise Failed("\{what}: expected \{quote(want)}, got \{quote(got)}")
  }
}

///|
fn expect_int(got : Int64, want : Int64, what : String) -> Unit raise Failed {
  guard got == want else {
    raise Failed("\{what}: expected \{want}, got \{got}")
  }
}

///|
fn expect_paths(
  got : Array[@sos.Entry],
  want : Array[String],
  what : String,
) -> Unit raise Failed {
  let actual = got.map(entry => entry.path)
  guard actual == want else {
    raise Failed(
      "\{what}: expected \{join_paths(want)}, got \{join_paths(actual)}",
    )
  }
}

///|
/// `work` must fail, and with this kind.
///
/// Succeeding is a failure here, and so is failing differently: a store that
/// answers `Unexpected` where the contract says `NotFound` has broken the seam
/// just as thoroughly as one that answers nothing.
async fn expect_kind(
  want : @sos.ErrorKind,
  what : String,
  work : async () -> Unit,
) -> Unit raise Failed {
  match attempt(work) {
    Some(@sos.SosError(kind~, ..)) => {
      guard kind == want else {
        raise Failed("\{what}: expected \{want}, got \{kind}")
      }
    }
    Some(_) =>
      raise Failed("\{what}: expected \{want}, got an error from outside sos")
    None => raise Failed("\{what}: expected \{want}, but the call succeeded")
  }
}

///|
/// Bytes as something a person can read in a failure message.
fn quote(data : Bytes) -> String {
  let out = StringBuilder()
  out.write_string("\"")
  for byte in data {
    let code = byte.to_int()
    if code >= 0x20 && code < 0x7F {
      out.write_char(code.unsafe_to_char())
    } else {
      out.write_string("\\x\{code.to_string(radix=16)}")
    }
  }
  out.write_string("\"")
  out.to_string()
}

///|
fn join_paths(paths : Array[String]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  for i, path in paths {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(path)
  }
  out.write_string("]")
  out.to_string()
}

///|
/// A failure message for anything a check can raise.
fn describe(err : Error) -> String {
  match err {
    Failed(message) => message
    @sos.SosError(_) as sos => sos.to_string()
    _ => "an error from outside sos"
  }
}
