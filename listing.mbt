// Turning a flat key space into a directory listing.
//
// `MemoryStore` and `IdbStore` both hold a flat map from path to bytes, and both
// have to answer `list` as if directories existed. That is the same problem
// twice, so it is solved once here, in the target-agnostic core, where it can be
// unit-tested on every backend without a store at all.
//
// A filesystem does not need `group_flat_listing` -- it has real directories --
// but it does need `apply_list_options`, so ordering, `start_after` and `limit`
// mean one thing across all three backends rather than three similar things.

///|
/// Directory listing over a flat key space.
///
/// `entries` is every record the backend holds, in any order: files, and the
/// directory markers it chose to materialise. Returns what `list(prefix, opts)`
/// should answer, ordered and filtered.
///
/// Non-recursive, a child that has a `/` left in it after the prefix comes back
/// as one `Dir` entry for its first segment, however many files are under it.
/// Recursive, every descendant comes back, plus a `Dir` entry for every
/// directory implied along the way -- so a caller sees the same tree whether or
/// not the backend bothered to store markers for it.
///
/// A real record always wins over a synthesised one: the marker knows its
/// `last_modified`, the synthesised entry does not.
pub fn group_flat_listing(
  prefix : String,
  entries : Iter[Entry],
  opts : ListOptions,
) -> Array[Entry] {
  let found : Map[String, Entry] = Map([])
  let synthesized : Map[String, Entry] = Map([])
  for entry in entries {
    guard entry.path.has_prefix(prefix) && entry.path != prefix else {
      continue
    }
    let rest = entry.path[prefix.length():]
    if opts.recursive {
      found[entry.path] = entry
      // Every directory between the prefix and this entry, whether or not the
      // backend stored a marker for it.
      for dir in ancestors(entry.path) {
        if dir.length() > prefix.length() && !synthesized.contains(dir) {
          synthesized[dir] = { path: dir, metadata: Metadata::dir(), }
        }
      }
    } else {
      match rest.find("/") {
        // Something deeper: report the directory it is in, not the entry.
        Some(i) => {
          let dir = prefix + rest[:i + 1].to_owned()
          if dir != entry.path && !synthesized.contains(dir) {
            synthesized[dir] = { path: dir, metadata: Metadata::dir(), }
          } else if dir == entry.path {
            found[entry.path] = entry
          }
        }
        None => found[entry.path] = entry
      }
    }
  }
  let out = []
  for path, entry in synthesized {
    if !found.contains(path) {
      out.push(entry)
    }
  }
  for _, entry in found {
    out.push(entry)
  }
  apply_list_options(out, opts)
}

///|
/// Order a listing and apply `start_after` and `limit`, in that order.
///
/// Ascending by path, always: `start_after` is only a resumable cursor if the
/// order it resumes into is the order it was produced in, and every backend
/// promises the same one.
pub fn apply_list_options(
  entries : Array[Entry],
  opts : ListOptions,
) -> Array[Entry] {
  entries.sort_by((x, y) => path_compare(x.path, y.path))
  let filtered = match opts.start_after {
    None => entries
    Some(after) => entries.filter(entry => path_lt(after, entry.path))
  }
  match opts.limit {
    Some(n) if n < filtered.length() => filtered[:n].to_owned()
    _ => filtered
  }
}
