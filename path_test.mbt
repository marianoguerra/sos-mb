// Path rules, table-driven.
//
// Plain `test`, not `async test`: nothing here touches a store, so these run
// under `moon test` on every backend with no scheduler and no dependency.

///|
test "normalize" {
  let cases = [
    // input, expected
    ("", ""),
    ("/", ""),
    (".", ""),
    ("./", ""),
    ("//", ""),
    ("///", ""),
    ("a", "a"),
    ("/a", "a"),
    ("a/", "a/"),
    ("/a/", "a/"),
    ("a//b", "a/b"),
    ("a/./b", "a/b"),
    ("./a/b", "a/b"),
    ("a/b/", "a/b/"),
    ("//a//b//", "a/b/"),
    ("a/b/c.txt", "a/b/c.txt"),
    // `..` survives normalization untouched; `validate` is what rejects it.
    ("a/../b", "a/../b"),
    // Non-ASCII segments are ordinary segments.
    ("día/año.txt", "día/año.txt"),
  ]
  for c in cases {
    let (input, expected) = c
    assert_eq((input, @sos.normalize(input)), (input, expected))
  }
}

///|
test "is_dir_path, ensure_dir_path and strip_dir_path" {
  assert_true(@sos.is_dir_path(""))
  assert_true(@sos.is_dir_path("a/"))
  assert_false(@sos.is_dir_path("a"))
  assert_eq(@sos.ensure_dir_path(""), "")
  assert_eq(@sos.ensure_dir_path("a"), "a/")
  assert_eq(@sos.ensure_dir_path("a/"), "a/")
  assert_eq(@sos.strip_dir_path(""), "")
  assert_eq(@sos.strip_dir_path("a/"), "a")
  assert_eq(@sos.strip_dir_path("a"), "a")
}

///|
test "parent" {
  let cases = [
    ("", ""),
    ("a", ""),
    ("a/", ""),
    ("a/b", "a/"),
    ("a/b/", "a/"),
    ("a/b/c", "a/b/"),
    ("a/b/c/", "a/b/"),
  ]
  for c in cases {
    let (input, expected) = c
    assert_eq((input, @sos.parent(input)), (input, expected))
  }
}

///|
test "basename" {
  let cases = [
    ("", ""),
    ("a", "a"),
    ("a/", "a/"),
    ("a/b", "b"),
    ("a/b/", "b/"),
    ("a/b/c.txt", "c.txt"),
  ]
  for c in cases {
    let (input, expected) = c
    assert_eq((input, @sos.basename(input)), (input, expected))
  }
}

///|
test "join" {
  let cases = [
    ("", "c", "c"),
    ("a", "c", "a/c"),
    ("a/", "c", "a/c"),
    ("a/b", "c", "a/b/c"),
    ("a/", "", "a/"),
    ("", "", ""),
    ("a/b", "c/d", "a/b/c/d"),
  ]
  for c in cases {
    let (base, child, expected) = c
    assert_eq((base, child, @sos.join(base, child)), (base, child, expected))
  }
}

///|
test "depth" {
  assert_eq(@sos.depth(""), 0)
  assert_eq(@sos.depth("a"), 1)
  assert_eq(@sos.depth("a/"), 1)
  assert_eq(@sos.depth("a/b/"), 2)
  assert_eq(@sos.depth("a/b/c.txt"), 3)
}

///|
test "ancestors" {
  assert_eq(@sos.ancestors(""), [])
  assert_eq(@sos.ancestors("a"), [])
  assert_eq(@sos.ancestors("a/"), [])
  assert_eq(@sos.ancestors("a/b"), ["a/"])
  assert_eq(@sos.ancestors("a/b/"), ["a/"])
  assert_eq(@sos.ancestors("a/b/c"), ["a/", "a/b/"])
  assert_eq(@sos.ancestors("a/b/c/d.txt"), ["a/", "a/b/", "a/b/c/"])
}

///|
test "validate accepts and normalizes" {
  assert_eq(@sos.validate("/a//b/", operation="t"), "a/b/")
  assert_eq(@sos.validate("", operation="t"), "")
  assert_eq(@sos.validate("a/b.txt", operation="t"), "a/b.txt")
}

///|
test "validate rejects paths that could escape or break a range scan" {
  let bad = [
    "..", "../a", "a/../b", "a/..", "a\\b", "C:/x", "a\u{0}b", "a\u{FFFF}b",
  ]
  for path in bad {
    let kind = try {
      @sos.validate(path, operation="t") |> ignore
      None
    } catch {
      err => Some(err.kind())
    }
    assert_eq((path, kind), (path, Some(@sos.InvalidPath)))
  }
}

///|
test "validate_file rejects a directory path" {
  assert_eq(@sos.validate_file("a/b.txt", operation="read"), "a/b.txt")
  for path in ["a/", ""] {
    let kind = try {
      @sos.validate_file(path, operation="read") |> ignore
      None
    } catch {
      err => Some(err.kind())
    }
    assert_eq((path, kind), (path, Some(@sos.IsADirectory)))
  }
}

///|
test "validate_dir coerces to directory form" {
  assert_eq(@sos.validate_dir("logs", operation="list"), "logs/")
  assert_eq(@sos.validate_dir("logs/", operation="list"), "logs/")
  assert_eq(@sos.validate_dir("", operation="list"), "")
  assert_eq(@sos.validate_dir("/a/b", operation="list"), "a/b/")
}

///|
test "path_compare is lexicographic where String::compare is length-first" {
  // The trap this function exists for: MoonBit's own String ordering puts the
  // shorter string first regardless of content.
  assert_true("b/" < "a.txt")
  assert_true(@sos.path_lt("a.txt", "b/"))
  assert_eq(@sos.path_compare("a", "a"), 0)
  assert_true(@sos.path_lt("a/b", "a/c"))
  assert_true(@sos.path_lt("a", "a/"))
  assert_true(@sos.path_lt("a/", "a0"))
  assert_true(@sos.path_lt("logs/2024", "logs/2025"))
}

///|
test "path_compare orders an astral character below the U+FFFF range bound" {
  // What keeps the IndexedDB prefix cursor honest: in code-unit order a
  // surrogate pair starts at 0xD800, which is below the 0xFFFF bound, so an
  // emoji-named key is inside the scanned range rather than past its end.
  assert_true(@sos.path_lt("p/\u{1F600}", "p/\u{FFFF}"))
}
