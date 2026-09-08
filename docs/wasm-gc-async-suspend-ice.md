# moonc ICE: calling `%async.suspend` on wasm-gc

`@sos/idbwasm` is in this repo but excluded from the published module
(`moon.mod`, `options(exclude:)`), because the compiler cannot generate code for
it. This is the report to file upstream, and the note to delete once it is
fixed.

## What happens

Any **call** to a function bound to the `%async.suspend` intrinsic crashes
`moonc` when the target is `wasm-gc`:

```
Error: Invalid_argument("Moonc.Basic_lst.fold_right2")
```

Preceded by the compiler's own "this is a bug in the compiler" banner, which
asks for exactly this report.

## Versions

```
moon   0.1.20260904 (94521db 2026-09-04)
moonc  v0.10.12+1634b282e (2026-09-07)
```

## Minimal reproduction

Two files. `moon.mod`:

```
name = "probe/ice"
version = "0.1.0"
```

`lib/moon.pkg`:

```
supported_targets = "wasm-gc"
```

`lib/a.mbt`:

```moonbit
///|
async fn suspend_int(register : ((Int) -> Unit) -> Unit) -> Int noraise = "%async.suspend"

///|
let waking : Ref[((Int) -> Unit)?] = { val: None }

///|
pub async fn go() -> Int noraise {
  suspend_int(k => waking.val = Some(k))
}
```

Then:

```bash
moon build --target wasm-gc
```

## What narrows it down

| | result |
|---|---|
| `--target js`, `native`, `wasm` | builds |
| `--target wasm-gc` | **ICE** |
| debug and release | both ICE |
| after `moon clean` | still ICEs |
| generic `fn[T] suspend(..) -> T` | ICE |
| monomorphic `fn suspend_int(..) -> Int` | ICE |
| `%async.suspend` declared but never called | builds |
| `%async.run` alone, no suspend | builds |

So it is the call, not the declaration; it is not the type parameter; and it is
specific to the wasm-gc code generator.

`moon check --target wasm-gc` **passes**. The failure is in code generation, not
in typing, so nothing that only checks will notice — including `moon publish`,
whose gate is a check.

## Why it blocks this package

On wasm-gc a MoonBit closure cannot cross into JavaScript, so there is nothing to
hand an `IDBRequest.onsuccess`. `idbwasm` instead hands JavaScript an `Int`
token, and JavaScript calls back into an export with it; `idbwasm/tokens.mbt`
parks the run in between. Parking is `%async.suspend`, and there is no other
primitive for it — `moonbitlang/async` is a scheduler built on the same
intrinsic, not an alternative to it.

`@sos/idbcore`, which holds the IndexedDB semantics both boundaries share, is
unaffected and ships: it is target-agnostic and has its own tests over a `Conn`
backed by a `Map`.
