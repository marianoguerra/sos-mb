// The JavaScript half of `@sos/idbwasm`, and the reference for embedding it.
//
// Every function here answers by calling back into an export with the token it
// was given, because on wasm-gc a MoonBit closure cannot cross into JavaScript
// and there is nothing to hand an `IDBRequest.onsuccess`. Exactly one of
// `on_sos_reply` / `on_sos_error` must be called for every token, exactly once,
// or the MoonBit call parks forever.
//
// An open connection lives in `handles` and MoonBit holds the row number.
//
// Object content crosses as base64 in both directions: the resume door carries
// a string, so bytes have to be spelled in one.

const handles = new Map();
let nextHandle = 0;

const b64encode = (bytes) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
};

const b64decode = (text) => {
  const binary = atob(text);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
};

export function createSosImports(getExports) {
  // One place where a settled Promise becomes a resumed MoonBit call, so the
  // "exactly once, always one of the two" rule is stated once rather than in
  // each of the seven.
  const settle = (token, work) => {
    Promise.resolve()
      .then(work)
      .then(
        (body) => getExports().on_sos_reply(token, body === undefined ? "" : body),
        (e) => getExports().on_sos_error(token, String(e && e.message ? e.message : e)),
      );
  };

  // Every operation goes through this, so "that connection is gone" is said
  // once and says which way it went. Without it a closed handle reaches
  // `h.db.transaction` and comes back as `InvalidStateError`, and an unknown one
  // as "cannot read properties of undefined" -- neither of which names the
  // connection or the mistake.
  const live = (handle) => {
    const h = handles.get(handle);
    if (!h) throw new Error(`connection ${handle} is not open`);
    if (h.closed) throw new Error(`connection ${handle} is closed`);
    return h;
  };

  const request = (h, mode, run) =>
    new Promise((resolve, reject) => {
      const tx = h.db.transaction(h.store, mode);
      const req = run(tx.objectStore(h.store));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });

  return {
    open(database, store, token) {
      settle(token, () => {
        if (typeof indexedDB === "undefined" || indexedDB === null) {
          throw new Error("this context has no indexedDB");
        }
        return new Promise((resolve, reject) => {
          const req = indexedDB.open(database, 1);
          req.onupgradeneeded = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains(store)) {
              db.createObjectStore(store, { keyPath: "path" });
            }
          };
          req.onsuccess = () => {
            const handle = ++nextHandle;
            handles.set(handle, { db: req.result, store, name: database, closed: false });
            resolve(String(handle));
          };
          req.onerror = () => reject(req.error);
        });
      });
    },

    get(handle, key, token) {
      settle(token, async () => {
        const h = live(handle);
        const v = await request(h, "readonly", (s) => s.get(key));
        if (v === undefined || v === null) return JSON.stringify({ found: false });
        return JSON.stringify({
          found: true,
          b64: b64encode(v.data ?? new Uint8Array(0)),
          c: v.ctype === undefined ? "" : v.ctype,
          m: v.mtime,
          d: v.dir === true,
        });
      });
    },

    put(handle, key, data, ctype, isDir, token) {
      settle(token, async () => {
        const h = live(handle);
        await request(h, "readwrite", (s) =>
          s.put({
            path: key,
            data: b64decode(data),
            ctype: ctype === "" ? undefined : ctype,
            // Stamped here rather than in MoonBit: the clock is the one thing
            // in this boundary that is genuinely the environment's.
            mtime: Date.now(),
            dir: isDir === 1 || isDir === true,
          }),
        );
        return "";
      });
    },

    deleteOne(handle, key, token) {
      settle(token, async () => {
        const h = live(handle);
        await request(h, "readwrite", (s) => s.delete(key));
        return "";
      });
    },

    deleteRange(handle, low, high, token) {
      settle(token, async () => {
        const h = live(handle);
        // The same bound the listing uses, so the two can never disagree about
        // what is under a path.
        const range = IDBKeyRange.bound(low, high, false, true);
        await request(h, "readwrite", (s) => s.delete(range));
        return "";
      });
    },

    scan(handle, low, high, token) {
      settle(token, () => {
        const h = live(handle);
        return new Promise((resolve, reject) => {
          const tx = h.db.transaction(h.store, "readonly");
          const range = IDBKeyRange.bound(low, high, false, true);
          const req = tx.objectStore(h.store).openCursor(range);
          const rows = [];
          req.onsuccess = () => {
            const cursor = req.result;
            if (!cursor) {
              resolve(JSON.stringify(rows));
              return;
            }
            const v = cursor.value;
            // Metadata only. The object content never crosses this call, so
            // listing a directory of large blobs costs what listing their names
            // costs.
            rows.push({
              p: v.path,
              n: v.data ? v.data.length : 0,
              m: v.mtime,
              c: v.ctype === undefined ? null : v.ctype,
              d: v.dir === true,
            });
            cursor.continue();
          };
          req.onerror = () => reject(req.error);
        });
      });
    },

    // Idempotent, and deliberately quiet about a handle it does not know: a
    // caller closing what it is done with should not have to remember whether it
    // already did. `live` is not used here for that reason -- a dead handle is
    // an error for an operation and a no-op for a release.
    close(handle, token) {
      settle(token, () => {
        const h = handles.get(handle);
        if (!h || h.closed) return "";
        h.db.close();
        // The row stays, holding the name, so `destroy` can still delete a
        // database whose connection was closed first. That is one small object
        // per closed handle, against a `destroy` that would otherwise find
        // nothing and silently leave the database on disk.
        h.closed = true;
        return "";
      });
    },

    destroy(handle, token) {
      settle(token, () => {
        const h = handles.get(handle);
        if (!h) return "";
        // `deleteDatabase` blocks while a connection is open, which is why the
        // close and the delete are one call.
        if (!h.closed) h.db.close();
        handles.delete(handle);
        return new Promise((resolve, reject) => {
          const req = indexedDB.deleteDatabase(h.name);
          req.onsuccess = () => resolve("");
          req.onerror = () => reject(req.error);
          req.onblocked = () => resolve("");
        });
      });
    },
  };
}
