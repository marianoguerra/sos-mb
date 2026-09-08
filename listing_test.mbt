// Directory synthesis over a flat key space.
//
// No store involved: `group_flat_listing` is a pure function over records, which
// is the whole reason it lives in the core instead of twice in the backends.

///|
fn file(path : String, size : Int64) -> @sos.Entry {
  { path, metadata: @sos.Metadata::file(size), }
}

///|
fn marker(path : String) -> @sos.Entry {
  { path, metadata: @sos.Metadata::dir(last_modified=7L), }
}

///|
fn paths(entries : Array[@sos.Entry]) -> Array[String] {
  entries.map(entry => entry.path)
}

///|
let sample : Array[@sos.Entry] = [
  file("a.txt", 3L),
  file("b/c.txt", 5L),
  file("b/d.txt", 7L),
  file("b/deep/e.txt", 9L),
  marker("empty/"),
]

///|
test "non-recursive listing reports one Dir per child directory" {
  let got = @sos.group_flat_listing(
    "",
    sample.iter(),
    @sos.ListOptions::default(),
  )
  assert_eq(paths(got), ["a.txt", "b/", "empty/"])
  assert_eq(got[0].metadata.mode, @sos.File)
  assert_eq(got[1].metadata.mode, @sos.Dir)
}

///|
test "a real directory marker keeps its metadata; a synthesised one has none" {
  let got = @sos.group_flat_listing(
    "",
    sample.iter(),
    @sos.ListOptions::default(),
  )
  // "b/" was synthesised from the files under it.
  assert_eq(got[1].metadata.last_modified, None)
  // "empty/" is a record the store actually holds.
  assert_eq(got[2].metadata.last_modified, Some(7L))
}

///|
test "listing a subdirectory" {
  let got = @sos.group_flat_listing(
    "b/",
    sample.iter(),
    @sos.ListOptions::default(),
  )
  assert_eq(paths(got), ["b/c.txt", "b/d.txt", "b/deep/"])
}

///|
test "recursive listing includes every implied directory" {
  let got = @sos.group_flat_listing("", sample.iter(), {
    ..@sos.ListOptions::default(),
    recursive: true,
  })
  assert_eq(paths(got), [
    "a.txt", "b/", "b/c.txt", "b/d.txt", "b/deep/", "b/deep/e.txt", "empty/",
  ])
}

///|
test "recursive listing of a subdirectory does not report the prefix itself" {
  let got = @sos.group_flat_listing("b/", sample.iter(), {
    ..@sos.ListOptions::default(),
    recursive: true,
  })
  assert_eq(paths(got), ["b/c.txt", "b/d.txt", "b/deep/", "b/deep/e.txt"])
}

///|
test "an empty key space lists as empty, it does not fail" {
  let got = @sos.group_flat_listing(
    "nothing/here/",
    sample.iter(),
    @sos.ListOptions::default(),
  )
  assert_eq(paths(got), [])
}

///|
test "limit truncates after ordering, not before" {
  let got = @sos.group_flat_listing("", sample.iter(), {
    ..@sos.ListOptions::default(),
    limit: Some(2),
  })
  assert_eq(paths(got), ["a.txt", "b/"])
}

///|
test "start_after resumes strictly after the given path" {
  let got = @sos.group_flat_listing("", sample.iter(), {
    ..@sos.ListOptions::default(),
    start_after: Some("b/"),
  })
  assert_eq(paths(got), ["empty/"])
}

///|
test "start_after and limit page through a listing" {
  let opts = { ..@sos.ListOptions::default(), recursive: true, limit: Some(3), }
  let first = @sos.group_flat_listing("", sample.iter(), opts)
  assert_eq(paths(first), ["a.txt", "b/", "b/c.txt"])
  let second = @sos.group_flat_listing("", sample.iter(), {
    ..opts,
    start_after: Some(first[first.length() - 1].path),
  })
  assert_eq(paths(second), ["b/d.txt", "b/deep/", "b/deep/e.txt"])
}

///|
test "apply_list_options sorts ascending" {
  let unsorted = [file("z", 1L), file("a", 1L), file("m", 1L)]
  let got = @sos.apply_list_options(unsorted, @sos.ListOptions::default())
  assert_eq(paths(got), ["a", "m", "z"])
}
