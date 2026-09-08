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
@sos/idbcore         the IndexedDB semantics, over a `Conn`     all targets
@sos/indexeddb       IndexedDB, reached by Promise              js
@sos/idbwasm         IndexedDB, reached by token and export     wasm-gc *
@sos/testing         one conformance suite, run by all of them  all targets
```

\* `@sos/idbwasm` is in the repository but **not in the published module**. Any
call to `%async.suspend` targeting wasm-gc crashes moonc as of
`v0.10.12+1634b282e`, and the token registry that backend parks calls in cannot
work without it. `moon check` passes, because the failure is in code generation
rather than typing. See [docs/wasm-gc-async-suspend-ice.md](docs/wasm-gc-async-suspend-ice.md)
for the repro; the exclusion in `moon.mod` comes out when the compiler can build
it again.

There are two ways into IndexedDB from MoonBit and they have nothing in common:
on `js` an `IDBRequest` becomes a `Promise`; on `wasm-gc` a closure cannot cross
into JavaScript at all, so a call hands JavaScript a token and JavaScript calls
back into an export with it. What they have in common is everything else —
implicit directories, the key bound, the range delete, the ancestor walk — so
that lives once in `@sos/idbcore`, over a six-method `Conn` seam, for the reason
`listing.mbt` gives about the listing. A `Conn` over a `Map` is then a store the
suite can run under `moon test`, which is how semantics that used to be
reachable only from a browser got unit tests.

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

| | memory | fs | both IndexedDB |
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
moon test --target wasm-gc -p marianoguerra/sos \
  -p marianoguerra/sos/memory -p marianoguerra/sos/idbcore
```

Core, memory and the IndexedDB semantics, on the backend with no event loop.
The packages are named one by one because a bare `moon test --target wasm-gc`
still reaches `idbwasm` and dies in the compiler; see the note at the top.

```bash
moon check --target all
```

Neither IndexedDB backend has a `moon test`: node has no `indexedDB`. Each is
verified in a real browser instead, against the same suite —

```bash
moon build --target js --release indexeddb/harness
python3 -m http.server 8731
```

Then open <http://localhost:8731/indexeddb/harness/index.html>. The page loads
the build output straight out of `_build/` and must report 33 passed, 1 skipped,
0 failed, the skip being `append`.

The wasm-gc harness is built the same way —

```bash
moon build --target wasm-gc --release idbwasm/harness
```

— and reported the same 33 passed, 1 skipped, 0 failed when it was written. It
does not build on the current compiler; see the note above.

`idbwasm/harness` is also the reference for embedding that backend. A host needs
three things and they are all in it: the two exports `on_sos_reply` /
`on_sos_error` in `main.mbt`, the `sosidb` import object, and a `run_async` to
start from — there is no event loop on wasm-gc, so the call that starts a run
finishes long before the run does.

The import object itself is `idbwasm/loader.mjs`, and it is the package's
contract rather than the harness's: copy it beside your page and spread
`createSosImports(getExports)` into the imports you instantiate with. A page is
served from one directory and an import that climbs out of it is a 403, which is
why it is copied rather than reached for where it lies.

## Demo

```bash
moon run cmd/main --target native
```

## What is not here

Deliberately, for now: streaming readers and writers, presign, versioning,
conditional headers, and layers (retry, logging, metrics). `read` and `write`
take and return whole `Bytes`.
