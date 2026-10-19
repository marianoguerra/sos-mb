// Store paths, and the rules that make them safe to hand a backend.
//
// A store path is not a filesystem path. It is relative to the store root,
// always uses `/`, and says whether it means a directory by ending in one. The
// root is `""`, never `"/"`.
//
// Every path a caller supplies goes through `validate` in `Operator` before any
// backend sees it. That is deliberate and it is load-bearing: because a
// validated path has no `..`, no leading `/` and no `\`, `FsStore` may
// concatenate it onto its root and cannot escape. Validation is here rather than
// in each backend so that there is one place to be right.

///|
/// Reduce `path` to canonical form. Total; never fails.
///
/// - runs of `/` collapse to one
/// - `.` segments drop
/// - a leading `/` drops
/// - a trailing `/` survives, because that is what says "directory" -- except
///   that the root is `""`, so `"/"`, `"."`, `"./"` and `"//"` all become `""`
///
/// `..` is NOT resolved. `validate` rejects it instead, because resolving it
/// would make `a/../../b` mean something and there is nothing above the root of
/// a store for it to mean.
pub fn normalize(path : String) -> String {
  let wants_dir = path.has_suffix("/")
  let segments = []
  for seg in path.split("/") {
    if seg != "" && seg != "." {
      segments.push(seg)
    }
  }
  if segments.is_empty() {
    return ""
  }
  let out = StringBuilder()
  for i, seg in segments {
    if i > 0 {
      out.write_string("/")
    }
    out.write_string(seg.to_owned())
  }
  if wants_dir {
    out.write_string("/")
  }
  out.to_string()
}

///|
/// True for the root (`""`) and for anything ending in `/`.
pub fn is_dir_path(path : String) -> Bool {
  path == "" || path.has_suffix("/")
}

///|
/// Append a `/` unless the path is the root or already has one.
pub fn ensure_dir_path(path : String) -> String {
  if is_dir_path(path) {
    path
  } else {
    path + "/"
  }
}

///|
/// Drop a trailing `/`. The root stays the root.
pub fn strip_dir_path(path : String) -> String {
  match path.strip_suffix("/") {
    Some(v) => v.to_owned()
    None => path
  }
}

///|
/// The containing directory, always in directory form.
///
/// `parent("a/b/c") == "a/b/"`, `parent("a/b/") == "a/"`, `parent("a") == ""`,
/// `parent("") == ""`.
pub fn parent(path : String) -> String {
  let stripped = strip_dir_path(path)
  if stripped == "" {
    return ""
  }
  match stripped.rev_find("/") {
    Some(i) => stripped[:i + 1].to_owned()
    None => ""
  }
}

///|
/// The last segment, keeping the `/` for a directory.
///
/// `basename("a/b/c") == "c"`, `basename("a/b/") == "b/"`, `basename("") == ""`.
pub fn basename(path : String) -> String {
  if path == "" {
    return ""
  }
  let dir = is_dir_path(path)
  let stripped = strip_dir_path(path)
  let base = match stripped.rev_find("/") {
    Some(i) => stripped[i + 1:].to_owned()
    None => stripped
  }
  if dir {
    base + "/"
  } else {
    base
  }
}

///|
/// Join, treating `base` as a directory whether or not it says so.
///
/// `join("a/b", "c") == "a/b/c"`, `join("", "c") == "c"`, `join("a/", "") == "a/"`.
pub fn join(base : String, child : String) -> String {
  if child == "" {
    base
  } else if base == "" {
    child
  } else {
    ensure_dir_path(base) + child
  }
}

///|
/// Number of `/`-separated segments. `depth("") == 0`, `depth("a/b/") == 2`.
pub fn depth(path : String) -> Int32 {
  let mut n = 0
  for seg in path.split("/") {
    if seg != "" {
      n = n + 1
    }
  }
  n
}

///|
/// Every strict ancestor directory, shallowest first, in directory form.
///
/// `ancestors("a/b/c") == ["a/", "a/b/"]`, `ancestors("a") == []`.
///
/// This is what the object-store backends walk to materialise the directory
/// records a filesystem gets for free from `mkdir -p`.
pub fn ancestors(path : String) -> Array[String] {
  let out = []
  let stripped = strip_dir_path(path)
  let mut acc = ""
  for seg in stripped.split("/") {
    if seg == "" {
      continue
    }
    if acc != "" {
      out.push(acc)
    }
    acc = acc + seg.to_owned() + "/"
  }
  out
}

///|
/// `normalize` plus the rules a store path must obey, or `InvalidPath`.
///
/// Rejects any `..` segment, a NUL, a `\`, a Windows drive prefix (`C:`), and
/// `U+FFFF`.
///
/// That last one looks arbitrary and is not: the IndexedDB backend bounds its
/// prefix cursor with `prefix + "\u{FFFF}"`, and the bound is only sound if no
/// stored key can contain the character. One rule in the core buys a correct
/// range scan in a backend.
pub fn validate(path : String, operation~ : String) -> String raise SosError {
  fn reject(why : String) -> SosError {
    SosError::new(InvalidPath, operation~, path~, message=why)
  }

  if path.contains_char('\u{0}') {
    raise reject("path contains a NUL")
  }
  if path.contains_char('\\') {
    raise reject("path contains a backslash; store paths always use '/'")
  }
  if path.contains_char('\u{FFFF}') {
    raise reject(
      "path contains U+FFFF, which is reserved as a range terminator",
    )
  }
  if path.get_char(1) is Some(':') {
    raise reject("path looks like a Windows drive; store paths are relative")
  }
  let normalized = normalize(path)
  for seg in normalized.split("/") {
    if seg == ".." {
      raise reject("path contains '..'; there is nothing above a store root")
    }
  }
  normalized
}

///|
/// `validate`, and reject a directory path.
///
/// For the operations that need bytes: `read`, `write`, `copy`, `rename`.
pub fn validate_file(
  path : String,
  operation~ : String,
) -> String raise SosError {
  let normalized = validate(path, operation~)
  guard !is_dir_path(normalized) else {
    raise SosError::new(
      IsADirectory,
      operation~,
      path=normalized,
      message="\{operation} needs a file path, not a directory",
    )
  }
  normalized
}

///|
/// `validate`, then `ensure_dir_path`, so a caller may write `list("logs")` and
/// mean the directory.
///
/// For `list` and `create_dir`.
pub fn validate_dir(
  path : String,
  operation~ : String,
) -> String raise SosError {
  ensure_dir_path(validate(path, operation~))
}

///|
/// Order two store paths, ascending, by UTF-16 code unit.
///
/// MoonBit's `Compare for String` is **length-first**: it compares lengths and
/// only then contents, so `"b/" < "a.txt"`. That is a fine total order and it is
/// not the one a listing promises -- pagination with `start_after` is only
/// resumable if "ascending" means what every other store means by it. So every
/// ordering decision in this library goes through here, and none through `<`.
///
/// Code units rather than code points, deliberately, because that is what
/// IndexedDB compares by. The `IdbStore` cursor is bounded by
/// `prefix + "\u{FFFF}"`, and in code-unit order every astral character starts
/// with a surrogate below `0xFFFF` and so stays inside the bound. In code-point
/// order it would not, and a key with an emoji in it would silently vanish from
/// a listing.
pub fn path_compare(a : String, b : String) -> Int32 {
  let shared = @cmp.minimum(a.length(), b.length())
  for i in 0..<shared {
    let order = a.at(i).compare(b.at(i))
    if order != 0 {
      return order
    }
  }
  a.length().compare(b.length())
}

///|
/// `path_compare(a, b) < 0`, for readability at call sites.
pub fn path_lt(a : String, b : String) -> Bool {
  path_compare(a, b) < 0
}
