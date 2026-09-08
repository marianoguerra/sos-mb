// The shared suite, against the in-memory store.
//
// Plain `test`, driven by `@testing.run_sync`, not `async test`. Two reasons,
// and both matter: this package imports no scheduler, so an `async test` here
// would silently never run; and `MemoryStore` never suspends, so it does not
// need one. That is what lets this exact check run on wasm-gc, where
// `moonbitlang/async`'s event loop is unimplemented.

///|
test "memory store passes the conformance suite" {
  @testing.run_sync(@memory.MemoryStore::new())
}

///|
test "the suite reports every check as passed or skipped, none failed" {
  let report = @testing.check_sync(@memory.MemoryStore::new())
  assert_eq(report.failures().length(), 0)
  // A memory store declares every capability, so nothing should be skipped
  // either -- if this drops, a capability was turned off without meaning to.
  assert_eq(report.skipped(), 0)
  assert_true(report.passed() > 20)
}

///|
test "the suite leaves nothing behind" {
  let store = @memory.MemoryStore::new()
  @testing.run_sync(store)
  assert_eq(store.size(), 0)
}
