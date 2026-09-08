///|
/// A store over a real directory tree.
///
/// The one backend here with real directories, which is the whole reason it is
/// worth having next to the other two: everything the `Store` contract says
/// about implicit directories is a claim that this and `MemoryStore` behave the
/// same, and the shared conformance suite is what checks it.
///
/// Native only. `moonbitlang/async/fs` is a POSIX/Windows binding, and a browser
/// has no filesystem to be portable to.
struct FsStore {
  /// An absolute or relative OS path with no trailing separator.
  root : String
}

///|
/// Anchor a store at `root`, creating the directory if it is not there.
///
/// Every store path is resolved under this and cannot leave it: `@sos.validate`
/// has already rejected `..`, a leading `/` and `\` by the time a path reaches
/// this backend, which is what makes plain concatenation safe here.
pub async fn FsStore::open(root : String) -> FsStore raise @sos.SosError {
  let root = @sos.strip_dir_path(root)
  guard root != "" else {
    raise @sos.SosError::new(
      @sos.ConfigInvalid,
      operation="open",
      message="FsStore needs a root directory",
    )
  }
  @osfs.mkdir(root, recursive=true) catch {
    err =>
      if !is_already_there(err) {
        raise translate(err, operation="open", path=root)
      }
  }
  { root, }
}

///|
/// The directory this store is anchored at.
pub fn FsStore::root(self : FsStore) -> String {
  self.root
}

///|
/// Was this "it is already there"?
///
/// `@osfs.mkdir(recursive=true)` is not quite `mkdir -p`: it still reports
/// EEXIST when the leaf already exists. Every caller here wants that to be
/// success, since `create_dir` is specified as idempotent and `write` has to be
/// able to run twice.
fn is_already_there(err : Error) -> Bool {
  match err {
    @os_error.OSError(_) as os => os.is_EEXIST()
    _ => false
  }
}

///|
/// The OS path for a store path.
///
/// The trailing `/` that marks a directory is a store convention, not a
/// filesystem one, so it comes off here.
fn FsStore::real(self : FsStore, path : String) -> String {
  let path = @sos.strip_dir_path(path)
  if path == "" {
    self.root
  } else {
    self.root + "/" + path
  }
}

///|
/// Modification time in epoch milliseconds, or `None` if it cannot be read.
async fn modified_ms(real : String) -> Int64? noraise {
  try {
    let (seconds, nanos) = @osfs.mtime(real)
    Some(seconds * 1000L + nanos.to_int64() / 1_000_000L)
  } catch {
    _ => None
  }
}

///|
/// Size of a regular file. Costs an open and a close; only called for files.
async fn file_size(real : String) -> Int64 {
  let file = @osfs.open(real, mode=ReadOnly)
  defer file.close()
  file.size()
}

///|
/// Metadata for an OS path already known to exist.
async fn describe(real : String, kind : @osfs.FileKind) -> @sos.Metadata {
  let last_modified = modified_ms(real)
  match kind {
    Regular => @sos.Metadata::file(file_size(real), last_modified?)
    Directory => @sos.Metadata::dir(last_modified?)
    _ =>
      {
        mode: @sos.Unknown,
        content_length: 0L,
        content_type: None,
        etag: None,
        last_modified,
      }
  }
}

///|
pub impl @sos.Store for FsStore with fn info(self) {
  {
    scheme: "fs",
    root: self.root,
    name: "",
    capability: {
      ..@sos.Capability::none(),
      read: true,
      read_with_range: true,
      write: true,
      write_can_append: true,
      // `write_with_content_type` stays false: a filesystem has nowhere to keep
      // one, and declaring it false is what makes `Operator` refuse a content
      // type here instead of accepting and silently dropping it.
      write_with_if_not_exists: true,
      stat: true,
      list: true,
      list_with_recursive: true,
      list_with_limit: true,
      list_with_start_after: true,
      delete: true,
      delete_with_recursive: true,
      create_dir: true,
      copy: true,
      rename: true,
      shared: true,
    },
  }
}

///|
pub impl @sos.Store for FsStore with fn read(self, path, opts) {
  let real = self.real(path)
  match opts.range {
    None =>
      @osfs.read_file(real).binary() catch {
        err => raise self.explain(err, operation="read", path~)
      }
    Some(range) => {
      let file = @osfs.open(real, mode=ReadOnly) catch {
        err => raise self.explain(err, operation="read", path~)
      }
      defer file.close()
      let size = file.size() catch {
        err => raise translate(err, operation="read", path~)
      }
      match range.resolve(size) {
        None =>
          raise @sos.SosError::new(
            @sos.RangeNotSatisfied,
            operation="read",
            path~,
            message="the object is \{size} bytes",
          )
        Some((offset, length)) =>
          file.read_exactly_at(length.to_int(), position=offset) catch {
            err => raise translate(err, operation="read", path~)
          }
      }
    }
  }
}

///|
pub impl @sos.Store for FsStore with fn write(self, path, data, opts) {
  let parent = @sos.parent(path)
  if parent != "" {
    @osfs.mkdir(self.real(parent), recursive=true) catch {
      err =>
        if !is_already_there(err) {
          raise translate(err, operation="write", path~)
        }
    }
  }
  // `CreateNew` is what turns `if_not_exists` into an EEXIST from the kernel
  // rather than a check-then-write with a race in the middle.
  let create_mode = if opts.if_not_exists {
    @osfs.CreateNew
  } else if opts.append {
    @osfs.OpenOrCreate
  } else {
    @osfs.CreateOrTruncate
  }
  @osfs.write_file(self.real(path), data, create_mode~, append=opts.append) catch {
    err => raise self.explain(err, operation="write", path~)
  }
}

///|
pub impl @sos.Store for FsStore with fn stat(self, path) {
  let real = self.real(path)
  let kind = @osfs.kind(real) catch {
    err => raise translate(err, operation="stat", path~)
  }
  describe(real, kind) catch {
    err => raise translate(err, operation="stat", path~)
  }
}

///|
pub impl @sos.Store for FsStore with fn list(self, path, opts) {
  let entries = []
  self.collect(path, opts.recursive, entries) catch {
    err => raise translate(err, operation="list", path~)
  }
  @sos.apply_list_options(entries, opts)
}

///|
pub impl @sos.Store for FsStore with fn delete(self, path, opts) {
  let real = self.real(path)
  // Absent is success. Asking first is also how this backend tells a file from a
  // directory without an EISDIR predicate to lean on.
  let kind = @osfs.kind(real) catch {
    err =>
      if is_missing(err) {
        return
      } else {
        raise translate(err, operation="delete", path~)
      }
  }
  match kind {
    Directory => {
      if !opts.recursive {
        let children = @osfs.readdir(real, include_hidden=true) catch {
          err => raise translate(err, operation="delete", path~)
        }
        guard children.is_empty() else {
          raise @sos.SosError::new(
            @sos.DirectoryNotEmpty,
            operation="delete",
            path~,
            message="pass recursive to remove it and everything under it",
          )
        }
      }
      @osfs.rmdir(real, recursive=opts.recursive) catch {
        err => raise translate(err, operation="delete", path~)
      }
    }
    _ =>
      @osfs.remove(real) catch {
        err =>
          if !is_missing(err) {
            raise translate(err, operation="delete", path~)
          }
      }
  }
}

///|
pub impl @sos.Store for FsStore with fn create_dir(self, path) {
  @osfs.mkdir(self.real(path), recursive=true) catch {
    err =>
      if !is_already_there(err) {
        raise translate(err, operation="create_dir", path~)
      }
  }
}

///|
/// One `rename(2)`, rather than the trait's copy-then-delete.
///
/// Atomic within a filesystem, and it never has both copies on disk at once --
/// which the default cannot promise and this can.
pub impl @sos.Store for FsStore with fn rename(self, from, to) {
  let parent = @sos.parent(to)
  if parent != "" {
    @osfs.mkdir(self.real(parent), recursive=true) catch {
      err =>
        if !is_already_there(err) {
          raise translate(err, operation="rename", path=to)
        }
    }
  }
  @osfs.rename(self.real(from), self.real(to), replace=true) catch {
    err => raise self.explain(err, operation="rename", path=from)
  }
}

///|
/// Was this "no such file"?
fn is_missing(err : Error) -> Bool {
  match err {
    @os_error.OSError(_) as os => os.is_ENOENT()
    _ => false
  }
}

///|
/// `translate`, with the one distinction `@os_error` cannot make.
///
/// There is no `is_EISDIR`, so when the kernel refuses an operation for a reason
/// this library would call `IsADirectory`, the only way to find out is to look
/// at the path. Done on the failure path only, so the cost lands where something
/// has already gone wrong.
async fn FsStore::explain(
  self : FsStore,
  err : Error,
  operation~ : String,
  path~ : String,
) -> @sos.SosError noraise {
  let translated = translate(err, operation~, path~)
  guard translated.kind() is (Unexpected | PermissionDenied) else {
    return translated
  }
  let is_dir = try (@osfs.kind(self.real(path)) is Directory) catch {
    _ => false
  }
  if is_dir {
    @sos.SosError::new(@sos.IsADirectory, operation~, path~)
  } else {
    translated
  }
}

///|
/// Walk a directory into `out`, in store-path form.
///
/// Two extra syscalls per entry -- a `kind` and, for a file, an open/size pair.
/// A `readdir` that carried sizes would avoid them; `@fs` does not have one, and
/// a listing whose `content_length` was always zero would be worse than a slow
/// one.
///
/// A missing directory contributes nothing rather than failing, because the
/// contract says an empty listing and an absent one look the same.
async fn FsStore::collect(
  self : FsStore,
  dir : String,
  recursive : Bool,
  out : Array[@sos.Entry],
) -> Unit {
  let real = self.real(dir)
  let names = @osfs.readdir(real, include_hidden=true) catch {
    err => if is_missing(err) { return } else { raise err }
  }
  for name in names {
    let child_real = real + "/" + name
    let kind = @osfs.kind(child_real) catch {
      // It went away between the readdir and the stat. Not this listing's
      // problem, and not worth failing the whole call over.
      _ => continue
    }
    let child = if kind is Directory {
      @sos.ensure_dir_path(dir) + name + "/"
    } else {
      @sos.ensure_dir_path(dir) + name
    }
    out.push({ path: child, metadata: describe(child_real, kind), })
    if recursive && kind is Directory {
      self.collect(child, recursive, out)
    }
  }
}
