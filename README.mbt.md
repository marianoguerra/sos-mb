# sos

Simple Object Storage: one storage interface, many backends.

`sos` is a small storage abstraction for MoonBit, modelled on
[Apache OpenDAL](https://opendal.apache.org/): application code reads and writes
blobs through one interface, and does not care whether the bytes live in a
`Map`, on disk, or in a browser database.

```
@sos                 the interface, the types, the path rules   all targets
@sos/memory          a Map                                      all targets
@sos/fs              a real directory tree                      native
@sos/indexeddb       the browser's IndexedDB                    js
@sos/testing         one conformance suite, run by all three    all targets
```

## The shape of it

Two layers, the way OpenDAL splits `Access` from `Operator`:

- **`Store`** is what a backend implements — eight async methods taking explicit
  option structs.
- **`Operator`** is what everyone else calls — labelled optional arguments, path
  validation, and capability checks before anything reaches the backend.

```
let op = @sos.Operator::new(@memory.MemoryStore::new())

op.write("notes/march.md", b"# March")
op.read("notes/march.md")                         // Bytes
op.read("notes/march.md", range=@sos.Range::prefix(7L))
op.list("notes/", recursive=true)                 // Array[Entry]
op.delete("notes/", recursive=true)
```

Also on `Operator`: `read_text`, `write_text`, `stat`, `exists`, `create_dir`,
`copy`, `rename`.

Every method is `async` and raises `SosError`. Nothing from a backend's own
dependencies escapes: a caller's `catch` sees the same error type whether the
failure came from a `Map`, from `errno`, or from an `IDBRequest`.

## Paths

Relative to the store root, always `/`, and a trailing `/` means directory. The
root is `""`, never `"/"`. `Operator` normalises and validates every path before
a backend sees it, which is what makes it safe for `FsStore` to concatenate one
onto its root: `..`, a leading `/`, `\` and `U+FFFF` are rejected outright.

Ordering is by `@sos.path_compare`, not by `<`. MoonBit's `Compare for String`
is length-first, so `"b/" < "a.txt"` — a fine total order, and not the one a
listing promises. `start_after` is only a resumable cursor if ascending means
what every other store means by it.

## Capabilities

A backend declares what it can do, and `Operator` refuses the rest before the
call lands:

| | memory | fs | indexeddb |
|---|---|---|---|
| ranged reads | yes | yes | yes |
| append | yes | yes | no — two transactions would race |
| content type | yes | no — nowhere to keep one | yes |
| shared between processes | no | yes | yes |

The conformance suite reads these flags to decide which checks to run, and
asserts the inverse as well: every flag that is `false` must produce
`Unsupported`, so a backend cannot under-declare its way out of a check.

## Testing a backend

```
// A store that never suspends, on any target, with no scheduler:
@testing.run_sync(@memory.MemoryStore::new())

// A store that does, under moonbitlang/async:
@testing.run(store)
```

`run_sync` uses the `%async.run` intrinsic, which drives an async computation on
the current stack. That is why the memory backend's conformance run works on
wasm-gc, where `moonbitlang/async`'s event loop is unimplemented.

Note that an `async test` in a package that does not import `moonbitlang/async`
compiles, never runs, and *passes* — moon's generated driver falls back to a
no-op. Packages here that have no scheduler use `run_sync` instead.

## Running the tests

```bash
moon test --target native
```

Core, memory and the filesystem backend.

```bash
moon test --target wasm-gc
```

Core and memory, on the backend with no event loop.

```bash
moon check --target all
```

IndexedDB has no `moon test`: node has no `indexedDB`. It is verified in a real
browser instead —

```bash
moon build --target js --release indexeddb/harness && python3 -m http.server 8731
```

Then open <http://localhost:8731/indexeddb/harness/index.html>. The page loads the
build output straight out of `_build/` and runs the same conformance suite that
`moon test` runs against the other two backends.

## Demo

```bash
moon run cmd/main --target native
```

## What is not here

Deliberately, for now: streaming readers and writers, presign, versioning,
conditional headers, and layers (retry, logging, metrics). `read` and `write`
take and return whole `Bytes`.
