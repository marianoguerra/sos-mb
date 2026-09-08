// The shared suite, against a real directory tree.
//
// `async test` here, not `@testing.run_sync`: this store genuinely suspends on
// every syscall, so it needs a scheduler. That is why this package imports
// `moonbitlang/async` `for "test"` -- moon's generated test driver only supplies
// `run_async_tests` when it is there, and without it an `async test` would
// compile, never run, and report a pass.
//
// The guard against exactly that is the first line of each test: a counter that
// a skipped test could not have incremented.

///|
let ran : Ref[Int] = { val: 0, }

///|
/// A fresh, empty directory nobody else is using.
async fn scratch(label : String) -> @fs.FsStore {
  ran.val = ran.val + 1
  @fs.FsStore::open(@osfs.tmpdir(prefix="sos-\{label}-"))
}

///|
async test "fs store passes the conformance suite" {
  let store = scratch("conformance")
  @testing.run(store)
  // Proof this body actually ran, rather than being a silent no-op.
  assert_true(ran.val > 0)
}

///|
async test "the suite skips exactly the capabilities a filesystem lacks" {
  let store = scratch("report")
  let report = @testing.check(store)
  assert_eq(report.failures().length(), 0)
  // A filesystem has nowhere to keep a content type, and that is the only thing
  // it cannot do. If this number moves, a capability changed.
  assert_eq(report.skipped(), 1)
  assert_true(report.passed() > 20)
}

///|
async test "the suite removes its own prefix" {
  let store = scratch("cleanup")
  @testing.run(store)
  let op = @sos.Operator::new(store)
  assert_eq(op.list("", recursive=true).map(entry => entry.path), [])
}

///|
async test "two stores over the same root see each other's writes" {
  let root = @osfs.tmpdir(prefix="sos-shared-")
  ran.val = ran.val + 1
  let writer = @sos.Operator::new(@fs.FsStore::open(root))
  let reader = @sos.Operator::new(@fs.FsStore::open(root))
  writer.write("shared/note.txt", b"visible")
  assert_eq(reader.read("shared/note.txt"), b"visible")
  assert_true(reader.info().capability.shared)
}
