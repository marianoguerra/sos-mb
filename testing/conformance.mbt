// One suite, every backend.
//
// The suite drives an `@sos.Operator`, not the raw `&Store`, so what it checks
// is the whole stack a user touches: path validation, capability gating and
// option-struct construction as well as the backend underneath.
//
// It takes the capability from `store.info()` rather than as an argument,
// because a capability passed separately could disagree with the one the store
// declares -- and disagreeing is precisely what this is here to catch. For every
// flag that is `false` it asserts the matching call raises `Unsupported`, so a
// backend cannot under-declare its way out of a check.

///|
priv struct Suite {
  op : @sos.Operator
  cap : @sos.Capability
  /// A directory the suite owns: it works only inside it and removes it after.
  prefix : String
  checks : Array[Check]
  /// `run` stops at the first failure; `check` records them all and continues.
  stop_on_failure : Bool
}

///|
/// Run every check against `store`, raising on the first failure.
///
/// `prefix` is a directory the suite owns outright: it is emptied before the run
/// and removed after, so two concurrent runs against one shared store need
/// different prefixes.
pub async fn run(
  store : &@sos.Store,
  prefix~ : String = "sos-conformance/",
) -> Unit {
  let report = execute(store, prefix, stop_on_failure=true)
  guard report.is_ok() else { raise Failed(report.to_string()) }
}

///|
/// The same checks, collected instead of raising.
///
/// For a backend under development, where the first failure is rarely the
/// interesting one.
pub async fn check(
  store : &@sos.Store,
  prefix~ : String = "sos-conformance/",
) -> Report noraise {
  execute(store, prefix, stop_on_failure=false)
}

///|
async fn execute(
  store : &@sos.Store,
  prefix : String,
  stop_on_failure~ : Bool,
) -> Report noraise {
  let suite = {
    op: @sos.Operator::new(store),
    cap: store.info().capability,
    prefix: @sos.ensure_dir_path(prefix),
    checks: [],
    stop_on_failure,
  }
  suite.scrub()
  suite.all() catch {
    _ => ()
  }
  suite.scrub()
  { checks: suite.checks, }
}

///|
/// A path inside the suite's own directory.
fn Suite::at(self : Suite, rest : String) -> String {
  self.prefix + rest
}

///|
/// Best-effort removal of everything the suite owns.
///
/// Deliberately swallows failures: a store with no recursive delete, or none at
/// all, still gets to run every other check. What it must not do is let a stale
/// object from a previous run make this one pass or fail for the wrong reason.
async fn Suite::scrub(self : Suite) -> Unit noraise {
  try {
    if self.cap.delete_with_recursive {
      self.op.delete(self.prefix, recursive=true)
    } else if self.cap.delete {
      for entry in self.op.list(self.prefix, recursive=true) {
        self.op.delete(entry.path) catch {
          _ => ()
        }
      }
    }
  } catch {
    _ => ()
  }
}

///|
/// Record one check, or note why it did not run.
async fn Suite::step(
  self : Suite,
  name : String,
  needs~ : Bool,
  requires~ : String,
  work : async () -> Unit,
) -> Unit raise Failed {
  guard needs else {
    self.checks.push({ name, skipped: Some(requires), failure: None, })
    return
  }
  match attempt(work) {
    None => self.checks.push({ name, skipped: None, failure: None, })
    Some(err) => {
      let why = describe(err)
      self.checks.push({ name, skipped: None, failure: Some(why), })
      if self.stop_on_failure {
        raise Failed("\{name}: \{why}")
      }
    }
  }
}

///|
async fn Suite::all(self : Suite) -> Unit raise Failed {
  self.roundtrip()
  self.ranges()
  self.write_options()
  self.listing()
  self.directories()
  self.deletion()
  self.moves()
  self.path_rules()
  self.unsupported_is_refused()
}

// -- reading and writing ----------------------------------------------------

///|
async fn Suite::roundtrip(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  let path = self.at("hello.txt")
  self.step(
    "write and read back",
    needs=cap.write && cap.read,
    requires="read+write",
    async fn() {
      op.write(path, b"hello")
      expect_bytes(op.read(path), b"hello", "content after write")
    },
  )
  self.step(
    "a second write replaces the first",
    needs=cap.write && cap.read,
    requires="read+write",
    async fn() {
      op.write(path, b"hello")
      op.write(path, b"bye")
      expect_bytes(op.read(path), b"bye", "content after overwrite")
    },
  )
  self.step(
    "reading a missing path is NotFound",
    needs=cap.read,
    requires="read",
    async fn() {
      expect_kind(@sos.NotFound, "read of a missing path", async fn() {
        op.read(self.at("no-such-file")) |> ignore
      })
    },
  )
  self.step(
    "stat reports mode and length",
    needs=cap.write && cap.stat,
    requires="stat",
    async fn() {
      op.write(path, b"12345")
      let meta = op.stat(path)
      expect(meta.mode is @sos.File, "stat mode of a file should be File")
      expect_int(meta.content_length, 5L, "stat content_length")
    },
  )
  self.step(
    "stat of a missing path is NotFound",
    needs=cap.stat,
    requires="stat",
    async fn() {
      expect_kind(@sos.NotFound, "stat of a missing path", async fn() {
        op.stat(self.at("no-such-file")) |> ignore
      })
    },
  )
  self.step(
    "exists follows write and delete",
    needs=cap.write && cap.stat && cap.delete,
    requires="stat+delete",
    async fn() {
      let probe = self.at("probe.txt")
      expect(!op.exists(probe), "should not exist before the write")
      op.write(probe, b"x")
      expect(op.exists(probe), "should exist after the write")
      op.delete(probe)
      expect(!op.exists(probe), "should not exist after the delete")
    },
  )
}

// -- ranged reads -----------------------------------------------------------

///|
async fn Suite::ranges(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  let path = self.at("range.txt")
  let needs = cap.write && cap.read && cap.read_with_range
  self.step("a range reads a slice", needs~, requires="read_with_range", async fn() {
    op.write(path, b"0123456789")
    expect_bytes(
      op.read(path, range=@sos.Range::between(2L, 5L)),
      b"234",
      "a bounded range",
    )
    expect_bytes(
      op.read(path, range=@sos.Range::from(7L)),
      b"789",
      "an open-ended range",
    )
    expect_bytes(
      op.read(path, range=@sos.Range::prefix(3L)),
      b"012",
      "a prefix range",
    )
  })
  self.step("a range past the end clamps", needs~, requires="read_with_range", async fn() {
    op.write(path, b"0123456789")
    expect_bytes(
      op.read(path, range=@sos.Range::between(8L, 100L)),
      b"89",
      "an end past the object",
    )
  })
  self.step(
    "a range starting past the end is RangeNotSatisfied",
    needs~,
    requires="read_with_range",
    async fn() {
      op.write(path, b"0123456789")
      expect_kind(@sos.RangeNotSatisfied, "a start past the object", async fn() {
        op.read(path, range=@sos.Range::from(11L)) |> ignore
      })
    },
  )
}

// -- write options ----------------------------------------------------------

///|
async fn Suite::write_options(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  self.step(
    "append extends an object, and creates a missing one",
    needs=cap.write_can_append && cap.read,
    requires="write_can_append",
    async fn() {
      let path = self.at("log.txt")
      op.write(path, b"one\n", append=true)
      op.write(path, b"two\n", append=true)
      expect_bytes(op.read(path), b"one\ntwo\n", "content after two appends")
    },
  )
  self.step(
    "if_not_exists refuses to overwrite",
    needs=cap.write_with_if_not_exists && cap.read,
    requires="write_with_if_not_exists",
    async fn() {
      let path = self.at("once.txt")
      op.write(path, b"first", if_not_exists=true)
      expect_kind(@sos.AlreadyExists, "a second conditional create", async fn() {
        op.write(path, b"second", if_not_exists=true)
      })
      expect_bytes(op.read(path), b"first", "the original content survives")
    },
  )
  self.step(
    "a content type survives a roundtrip",
    needs=cap.write_with_content_type && cap.stat,
    requires="write_with_content_type",
    async fn() {
      let path = self.at("typed.json")
      op.write(path, b"{}", content_type="application/json")
      expect(
        op.stat(path).content_type == Some("application/json"),
        "stat should report the content type that was written",
      )
    },
  )
}

// -- listing ----------------------------------------------------------------

///|
/// The tree every listing check runs against.
async fn Suite::seed(self : Suite) -> Unit {
  self.op.write(self.at("tree/a.txt"), b"a")
  self.op.write(self.at("tree/b.txt"), b"b")
  self.op.write(self.at("tree/sub/c.txt"), b"c")
  self.op.write(self.at("tree/sub/deeper/d.txt"), b"d")
}

///|
async fn Suite::listing(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  let tree = self.at("tree/")
  let needs = cap.write && cap.list
  self.step("write creates every missing ancestor", needs~, requires="list", async fn() {
    self.seed()
    let got = op.list(tree)
    expect_paths(
      got,
      [tree + "a.txt", tree + "b.txt", tree + "sub/"],
      "children of tree/",
    )
    expect(got[2].is_dir(), "sub/ should be reported as a directory")
  })
  self.step("a listing is ascending by path", needs~, requires="list", async fn() {
    self.seed()
    let got = op.list(tree).map(entry => entry.path)
    for i in 1..<got.length() {
      expect(
        @sos.path_lt(got[i - 1], got[i]),
        "listing out of order: \{got[i - 1]} before \{got[i]}",
      )
    }
  })
  self.step(
    "listing accepts a path without a trailing slash",
    needs~,
    requires="list",
    async fn() {
      self.seed()
      expect_paths(
        op.list(@sos.strip_dir_path(tree)),
        op.list(tree).map(e => e.path),
        "list('tree') vs list('tree/')",
      )
    },
  )
  self.step(
    "an empty directory lists as empty rather than failing",
    needs~,
    requires="list",
    async fn() {
      expect_paths(
        op.list(self.at("definitely/not/here/")),
        [],
        "listing a path with nothing under it",
      )
    },
  )
  self.step(
    "a recursive listing reaches every descendant",
    needs=needs && cap.list_with_recursive,
    requires="list_with_recursive",
    async fn() {
      self.seed()
      expect_paths(
        op.list(tree, recursive=true),
        [
          tree + "a.txt",
          tree + "b.txt",
          tree + "sub/",
          tree + "sub/c.txt",
          tree + "sub/deeper/",
          tree + "sub/deeper/d.txt",
        ],
        "every descendant of tree/",
      )
    },
  )
  self.step(
    "limit truncates the listing",
    needs=needs && cap.list_with_limit,
    requires="list_with_limit",
    async fn() {
      self.seed()
      expect_paths(
        op.list(tree, limit=2),
        [tree + "a.txt", tree + "b.txt"],
        "the first two children",
      )
    },
  )
  self.step(
    "start_after resumes a listing",
    needs=needs && cap.list_with_start_after,
    requires="list_with_start_after",
    async fn() {
      self.seed()
      expect_paths(
        op.list(tree, start_after=tree + "a.txt"),
        [tree + "b.txt", tree + "sub/"],
        "children after a.txt",
      )
    },
  )
  self.step(
    "limit and start_after page through a listing",
    needs=needs && cap.list_with_limit && cap.list_with_start_after,
    requires="list_with_limit+start_after",
    async fn() {
      self.seed()
      let first = op.list(tree, limit=2)
      let second = op.list(
        tree,
        limit=2,
        start_after=first[first.length() - 1].path,
      )
      expect_paths(second, [tree + "sub/"], "the second page")
    },
  )
}

// -- directories ------------------------------------------------------------

///|
async fn Suite::directories(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  self.step(
    "create_dir is idempotent and the directory is listable",
    needs=cap.create_dir && cap.list,
    requires="create_dir",
    async fn() {
      let dir = self.at("made/")
      op.create_dir(dir)
      op.create_dir(dir)
      expect_paths(op.list(dir), [], "a directory created and left empty")
      let parent = op.list(self.prefix).map(entry => entry.path)
      expect(
        parent.contains(dir),
        "\{dir} should appear in \{self.prefix}, got \{join_paths(parent)}",
      )
    },
  )
  self.step(
    "create_dir accepts a path without a trailing slash",
    needs=cap.create_dir && cap.list,
    requires="create_dir",
    async fn() {
      op.create_dir(self.at("bare"))
      let parent = op.list(self.prefix).map(entry => entry.path)
      expect(
        parent.contains(self.at("bare/")),
        "a directory made from a bare name is still a directory",
      )
    },
  )
  self.step(
    "a file path is not a directory path",
    needs=cap.write && cap.read,
    requires="read+write",
    async fn() {
      expect_kind(@sos.IsADirectory, "reading a directory path", async fn() {
        op.read(self.at("tree/")) |> ignore
      })
    },
  )
}

// -- deletion ---------------------------------------------------------------

///|
async fn Suite::deletion(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  self.step(
    "deleting an absent path succeeds",
    needs=cap.delete,
    requires="delete",
    async fn() { op.delete(self.at("never-existed")) },
  )
  self.step(
    "delete is idempotent",
    needs=cap.delete && cap.write,
    requires="delete",
    async fn() {
      let path = self.at("twice.txt")
      op.write(path, b"x")
      op.delete(path)
      op.delete(path)
    },
  )
  self.step(
    "a non-empty directory needs recursive",
    needs=cap.delete && cap.write,
    requires="delete",
    async fn() {
      self.seed()
      expect_kind(@sos.DirectoryNotEmpty, "deleting a populated directory", async fn() {
        op.delete(self.at("tree/"))
      })
    },
  )
  self.step(
    "a recursive delete removes the whole subtree",
    needs=cap.delete_with_recursive && cap.write && cap.list,
    requires="delete_with_recursive",
    async fn() {
      self.seed()
      op.delete(self.at("tree/"), recursive=true)
      expect_paths(
        op.list(self.at("tree/"), recursive=true),
        [],
        "what is left under tree/",
      )
    },
  )
}

// -- copy and rename --------------------------------------------------------

///|
async fn Suite::moves(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  self.step(
    "copy leaves both objects",
    needs=cap.copy && cap.write && cap.read,
    requires="copy",
    async fn() {
      let from = self.at("copy-from.txt")
      let to = self.at("copied/to.txt")
      op.write(from, b"payload")
      op.copy(from, to)
      expect_bytes(op.read(to), b"payload", "the copy")
      expect_bytes(op.read(from), b"payload", "the original")
    },
  )
  self.step(
    "copying a missing object is NotFound",
    needs=cap.copy,
    requires="copy",
    async fn() {
      expect_kind(@sos.NotFound, "copying a missing object", async fn() {
        op.copy(self.at("no-such-source"), self.at("anywhere"))
      })
    },
  )
  self.step(
    "rename moves the object",
    needs=cap.rename && cap.write && cap.read && cap.stat,
    requires="rename",
    async fn() {
      let from = self.at("rename-from.txt")
      let to = self.at("renamed/to.txt")
      op.write(from, b"payload")
      op.rename(from, to)
      expect_bytes(op.read(to), b"payload", "the renamed object")
      expect(!op.exists(from), "the source should be gone after a rename")
    },
  )
}

// -- the rules the core enforces -------------------------------------------

///|
async fn Suite::path_rules(self : Suite) -> Unit raise Failed {
  let op = self.op
  self.step(
    "a path that would escape the root is refused",
    needs=true,
    requires="",
    async fn() {
      for bad in ["../outside.txt", "a/../../outside.txt", "a\\b.txt"] {
        expect_kind(@sos.InvalidPath, "reading '\{bad}'", async fn() {
          op.read(bad) |> ignore
        })
      }
    },
  )
  self.step(
    "a leading slash is normalized, not rejected",
    needs=self.cap.write && self.cap.read,
    requires="read+write",
    async fn() {
      let path = self.at("slashed.txt")
      op.write("/" + path, b"x")
      expect_bytes(
        op.read(path),
        b"x",
        "an absolute-looking path names the same object",
      )
    },
  )
}

///|
/// Every capability the backend does NOT declare must produce `Unsupported`.
///
/// This is the half that keeps `Capability` honest. Without it a backend could
/// leave a flag false, watch the suite skip the check, and ship an operation
/// that fails in some other way -- or worse, silently half-works.
async fn Suite::unsupported_is_refused(self : Suite) -> Unit raise Failed {
  let cap = self.cap
  let op = self.op
  let path = self.at("gated.txt")
  self.step(
    "an undeclared operation is refused with Unsupported",
    needs=true,
    requires="",
    async fn() {
      if !cap.read {
        expect_kind(@sos.Unsupported, "read", async fn() {
          op.read(path) |> ignore
        })
      }
      if !cap.write {
        expect_kind(@sos.Unsupported, "write", async fn() {
          op.write(path, b"x")
        })
      }
      if !cap.stat {
        expect_kind(@sos.Unsupported, "stat", async fn() {
          op.stat(path) |> ignore
        })
      }
      if !cap.list {
        expect_kind(@sos.Unsupported, "list", async fn() {
          op.list(self.prefix) |> ignore
        })
      }
      if !cap.delete {
        expect_kind(@sos.Unsupported, "delete", async fn() { op.delete(path) })
      }
      if !cap.create_dir {
        expect_kind(@sos.Unsupported, "create_dir", async fn() {
          op.create_dir(self.at("d/"))
        })
      }
      if !cap.copy {
        expect_kind(@sos.Unsupported, "copy", async fn() {
          op.copy(path, self.at("other.txt"))
        })
      }
      if !cap.rename {
        expect_kind(@sos.Unsupported, "rename", async fn() {
          op.rename(path, self.at("other.txt"))
        })
      }
    },
  )
  self.step(
    "an undeclared option is refused with Unsupported",
    needs=true,
    requires="",
    async fn() {
      if cap.read && !cap.read_with_range {
        expect_kind(@sos.Unsupported, "a ranged read", async fn() {
          op.read(path, range=@sos.Range::from(1L)) |> ignore
        })
      }
      if cap.write && !cap.write_can_append {
        expect_kind(@sos.Unsupported, "append", async fn() {
          op.write(path, b"x", append=true)
        })
      }
      if cap.write && !cap.write_with_content_type {
        expect_kind(@sos.Unsupported, "a content type", async fn() {
          op.write(path, b"x", content_type="text/plain")
        })
      }
      if cap.write && !cap.write_with_if_not_exists {
        expect_kind(@sos.Unsupported, "if_not_exists", async fn() {
          op.write(path, b"x", if_not_exists=true)
        })
      }
      if cap.list && !cap.list_with_recursive {
        expect_kind(@sos.Unsupported, "a recursive listing", async fn() {
          op.list(self.prefix, recursive=true) |> ignore
        })
      }
      if cap.list && !cap.list_with_limit {
        expect_kind(@sos.Unsupported, "limit", async fn() {
          op.list(self.prefix, limit=1) |> ignore
        })
      }
      if cap.list && !cap.list_with_start_after {
        expect_kind(@sos.Unsupported, "start_after", async fn() {
          op.list(self.prefix, start_after="a") |> ignore
        })
      }
      if cap.delete && !cap.delete_with_recursive {
        expect_kind(@sos.Unsupported, "a recursive delete", async fn() {
          op.delete(self.at("d/"), recursive=true)
        })
      }
    },
  )
}
