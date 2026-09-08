// What is specific to holding everything in a map.
//
// The shared suite covers the contract; this covers the choices this backend
// makes underneath it -- implicit directories, explicit markers, and a clock
// that is a counter.

///|
fn drive(work : async () -> Unit noraise) -> Unit = "%async.run"

///|
/// Run an operator body here, on this stack, surfacing whatever it raised.
fn with_memory(work : async (@sos.Operator) -> Unit) -> Unit raise {
  let store = @memory.MemoryStore::new()
  let op = @sos.Operator::new(store)
  let caught : Ref[Error?] = { val: None, }
  drive(async fn() noraise { work(op) catch { err => caught.val = Some(err) } })
  if caught.val is Some(err) {
    raise err
  }
}

///|
test "directories are implicit: nothing is stored for them" {
  let store = @memory.MemoryStore::new()
  let op = @sos.Operator::new(store)
  let caught : Ref[Error?] = { val: None, }
  drive(async fn() noraise {
    op.write("a/b/c.txt", b"x") catch {
      err => caught.val = Some(err)
    }
  })
  assert_true(caught.val is None)
  // One record for one object, not three for the object and its two ancestors.
  assert_eq(store.size(), 1)
}

///|
test "an implicit directory still stats as a directory" {
  with_memory(async fn(op) {
    op.write("a/b/c.txt", b"x")
    assert_true(op.stat("a/b/").is_dir())
    assert_true(op.exists("a/"))
  })
}

///|
test "an explicitly created empty directory survives, having nothing under it" {
  with_memory(async fn(op) {
    op.create_dir("empty/")
    assert_eq(op.list("").map(e => e.path), ["empty/"])
    // And it is still there once a sibling appears.
    op.write("other.txt", b"x")
    assert_eq(op.list("").map(e => e.path), ["empty/", "other.txt"])
  })
}

///|
test "create_dir materialises every ancestor, so an empty tree is walkable" {
  with_memory(async fn(op) {
    op.create_dir("a/b/c/")
    assert_eq(op.list("").map(e => e.path), ["a/"])
    assert_eq(op.list("a/").map(e => e.path), ["a/b/"])
    assert_eq(op.list("a/b/").map(e => e.path), ["a/b/c/"])
    assert_eq(op.list("a/b/c/").map(e => e.path), [])
  })
}

///|
test "last_modified is a counter: monotone, and not a wall clock" {
  with_memory(async fn(op) {
    op.write("first.txt", b"1")
    op.write("second.txt", b"2")
    let first = op.stat("first.txt").last_modified.unwrap()
    let second = op.stat("second.txt").last_modified.unwrap()
    assert_true(second > first)
    assert_eq(first, 1L)
    assert_eq(second, 2L)
  })
}

///|
test "writing to a directory path is refused" {
  with_memory(async fn(op : @sos.Operator) {
    op.create_dir("d/")
    // "d/" is a directory path, so the operator rejects it before the store.
    let caught : @sos.ErrorKind? = try {
      op.write("d/", b"x")
      None
    } catch {
      @sos.SosError(kind~, ..) => Some(kind)
    }
    assert_eq(caught, Some(@sos.IsADirectory))
  })
}

///|
test "two stores share nothing" {
  let a = @memory.MemoryStore::new(name="a")
  let b = @memory.MemoryStore::new(name="b")
  let op_a = @sos.Operator::new(a)
  drive(async fn() noraise { op_a.write("k.txt", b"x") catch { _ => () } })
  assert_eq(a.size(), 1)
  assert_eq(b.size(), 0)
  assert_false(@sos.Operator::new(b).info().capability.shared)
}
