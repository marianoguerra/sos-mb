// A tour of the API, over a real directory.
//
// Native, because it uses the filesystem backend. Swapping `@fs.FsStore::open`
// for `@memory.MemoryStore::new()` is the only change needed to run the same
// body on any target -- which is the point of `Operator` taking a `&Store`.
//
// Run with `moon run cmd/main --target native`.

///|
async fn main {
  let root = @osfs.tmpdir(prefix="sos-demo-")
  let op = @sos.Operator::new(@fs.FsStore::open(root))
  println("store: \{op.info().scheme} at \{op.info().root}\n")
  op.write_text("notes/2026/march.md", "# March\nshipped sos\n")
  op.write_text("notes/2026/april.md", "# April\n")
  op.write("assets/logo.bin", b"\x89PNG")
  op.create_dir("drafts/")
  println("everything under the root:")
  for entry in op.list("", recursive=true) {
    let kind = if entry.is_dir() { "dir " } else { "file" }
    println("  \{kind} \{entry.path} (\{entry.metadata.content_length} bytes)")
  }
  println("\nimmediate children of notes/:")
  for entry in op.list("notes") {
    println("  \{entry.path}")
  }
  println("\nread back: \{op.read_text("notes/2026/march.md").trim()}")
  println(
    "first 7 bytes: \{op.read_text("notes/2026/march.md", range=@sos.Range::prefix(7L))}",
  )
  op.copy("notes/2026/march.md", "backup/march.md")
  op.rename("notes/2026/april.md", "notes/2026/april-final.md")
  println("\nafter copy and rename:")
  for entry in op.list("", recursive=true) {
    if !entry.is_dir() {
      println("  \{entry.path}")
    }
  }
  println(
    "\nexists('notes/2026/april.md') = \{op.exists("notes/2026/april.md")}",
  )
  let refused = try {
    op.write("notes/../../escape.txt", b"nope")
    "no error"
  } catch {
    err => "\{err}"
  }
  println("escaping path: \{refused}")
  op.delete("", recursive=true)
  println(
    "\nafter a recursive delete: \{op.list("", recursive=true).length()} entries",
  )
}
