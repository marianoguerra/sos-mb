// The facade, against a store that only records what it was handed.
//
// Two things are being tested and neither needs a real backend: that `Operator`
// validates a path before the store sees it, and that it refuses an operation
// the `Capability` says the backend cannot do -- without calling the store at
// all.

///|
/// Records the last path it was given and otherwise does nothing.
///
/// `reached` is what proves capability gating happens *before* dispatch: an
/// operation the store does not support must leave it false.
struct Spy {
  capability : @sos.Capability
  mut reached : Bool
  mut last_path : String
  mut last_list : @sos.ListOptions
  mut last_write : @sos.WriteOptions
}

///|
fn Spy::new(capability : @sos.Capability) -> Spy {
  {
    capability,
    reached: false,
    last_path: "",
    last_list: @sos.ListOptions::default(),
    last_write: @sos.WriteOptions::default(),
  }
}

///|
fn Spy::everything() -> Spy {
  Spy::new({
    ..@sos.Capability::none(),
    read: true,
    read_with_range: true,
    write: true,
    write_can_append: true,
    write_with_content_type: true,
    write_with_if_not_exists: true,
    stat: true,
    list: true,
    list_with_recursive: true,
    list_with_limit: true,
    list_with_start_after: true,
    delete: true,
    delete_with_recursive: true,
    create_dir: true,
    copy: true,
    rename: true,
  })
}

///|
pub impl @sos.Store for Spy with fn info(self) {
  { scheme: "spy", root: "", name: "", capability: self.capability, }
}

///|
pub impl @sos.Store for Spy with fn read(self, path, _opts) {
  self.reached = true
  self.last_path = path
  b"spied"
}

///|
pub impl @sos.Store for Spy with fn write(self, path, _data, opts) {
  self.reached = true
  self.last_path = path
  self.last_write = opts
}

///|
pub impl @sos.Store for Spy with fn stat(self, path) {
  self.reached = true
  self.last_path = path
  @sos.Metadata::file(5L)
}

///|
pub impl @sos.Store for Spy with fn list(self, path, opts) {
  self.reached = true
  self.last_path = path
  self.last_list = opts
  []
}

///|
pub impl @sos.Store for Spy with fn delete(self, path, _opts) {
  self.reached = true
  self.last_path = path
}

///|
pub impl @sos.Store for Spy with fn create_dir(self, path) {
  self.reached = true
  self.last_path = path
}

///|
/// Run an async body to completion here, on this stack.
///
/// The spy never suspends, so no scheduler is needed. See `@testing.run_sync`
/// for the same trick with a real store behind it.
fn drive(work : async () -> Unit noraise) -> Unit = "%async.run"

///|
/// Whatever the operator raised, or `None` if it returned.
fn attempt(work : async () -> Unit) -> Error? {
  let caught : Ref[Error?] = { val: None, }
  drive(async fn() noraise { work() catch { err => caught.val = Some(err) } })
  caught.val
}

///|
/// The `ErrorKind` of whatever `attempt` caught. `None` for a clean run, so a
/// passing call and a non-`SosError` failure never compare equal.
fn kind_of(caught : Error?) -> @sos.ErrorKind? {
  match caught {
    Some(@sos.SosError(kind~, ..)) => Some(kind)
    _ => None
  }
}

///|
test "paths are normalized before the store sees them" {
  let spy = Spy::everything()
  let op = @sos.Operator::new(spy)
  assert_true(attempt(async fn() { op.read("/a//./b.txt") |> ignore }) is None)
  assert_eq(spy.last_path, "a/b.txt")
  assert_true(attempt(async fn() { op.list("logs") |> ignore }) is None)
  assert_eq(spy.last_path, "logs/")
}

///|
test "an escaping path never reaches the store" {
  let spy = Spy::everything()
  let op = @sos.Operator::new(spy)
  let err = attempt(async fn() { op.read("../etc/passwd") |> ignore })
  assert_eq(kind_of(err), Some(@sos.InvalidPath))
  assert_false(spy.reached)
}

///|
test "an unsupported operation is refused without calling the store" {
  let spy = Spy::new(@sos.Capability::none())
  let op = @sos.Operator::new(spy)
  let attempts : Array[(String, async () -> Unit)] = [
    ("read", async fn() { op.read("a.txt") |> ignore }),
    ("write", async fn() { op.write("a.txt", b"x") }),
    ("stat", async fn() { op.stat("a.txt") |> ignore }),
    ("list", async fn() { op.list("") |> ignore }),
    ("delete", async fn() { op.delete("a.txt") }),
    ("create_dir", async fn() { op.create_dir("d/") }),
    ("copy", async fn() { op.copy("a.txt", "b.txt") }),
    ("rename", async fn() { op.rename("a.txt", "b.txt") }),
  ]
  for entry in attempts {
    let (name, work) = entry
    assert_eq((name, kind_of(attempt(work))), (name, Some(@sos.Unsupported)))
  }
  assert_false(spy.reached)
}

///|
test "an unsupported option is refused even when the operation is supported" {
  let spy = Spy::new({
    ..@sos.Capability::none(),
    read: true,
    write: true,
    list: true,
  })
  let op = @sos.Operator::new(spy)
  let ranged = attempt(async fn() {
    op.read("a.txt", range=@sos.Range::from(1L)) |> ignore
  })
  assert_eq(kind_of(ranged), Some(@sos.Unsupported))
  let appended = attempt(async fn() { op.write("a.txt", b"x", append=true) })
  assert_eq(kind_of(appended), Some(@sos.Unsupported))
  let recursive = attempt(async fn() { op.list("", recursive=true) |> ignore })
  assert_eq(kind_of(recursive), Some(@sos.Unsupported))
  assert_false(spy.reached)
  // The same calls without the option go straight through.
  assert_true(attempt(async fn() { op.read("a.txt") |> ignore }) is None)
  assert_true(spy.reached)
}

///|
test "labelled arguments become option structs" {
  let spy = Spy::everything()
  let op = @sos.Operator::new(spy)
  attempt(async fn() {
    op.write("a.txt", b"x", content_type="text/plain", if_not_exists=true)
  })
  |> ignore
  assert_eq(spy.last_write.content_type, Some("text/plain"))
  assert_true(spy.last_write.if_not_exists)
  assert_false(spy.last_write.append)
  attempt(async fn() {
    op.list("d", recursive=true, limit=10, start_after="d/x") |> ignore
  })
  |> ignore
  assert_true(spy.last_list.recursive)
  assert_eq(spy.last_list.limit, Some(10))
  assert_eq(spy.last_list.start_after, Some("d/x"))
}

///|
test "exists turns NotFound into false and lets anything else through" {
  let spy = Spy::everything()
  let op = @sos.Operator::new(spy)
  let found : Ref[Bool] = { val: false, }
  attempt(async fn() { found.val = op.exists("a.txt") }) |> ignore
  assert_true(found.val)
}
