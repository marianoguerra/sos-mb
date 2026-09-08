// Instantiating the harness. The IndexedDB half is `../loader.mjs`, which is
// this package's import contract and what a host copies; this file is only how
// one page happens to load one module.

import { createSosImports } from "../loader.mjs";

export { createSosImports };

// Fetch and instantiate a wasm-gc module with the `sosidb` namespace supplied.
// `makeExtra` is whatever else the host links in -- the harness uses it for its
// own `publish`.
export async function instantiate(wasmUrl, makeExtra) {
  let exports = null;
  const getExports = () => exports;
  const imports = {
    sosidb: createSosImports(getExports),
    // MoonBit's println lowers to a `console.log` import on wasm-gc.
    console: { log: (...a) => console.log(...a) },
    ...(makeExtra ? makeExtra(getExports) : {}),
  };
  const opts = { builtins: ["js-string"], importedStringConstants: "_" };
  const { instance } = await WebAssembly.instantiateStreaming(
    fetch(wasmUrl),
    imports,
    opts,
  );
  exports = instance.exports;
  if (exports._start) exports._start();
  return exports;
}
