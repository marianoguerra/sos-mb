///|
/// A half-open byte range, `[start, end)`.
///
/// Half-open rather than inclusive because every slice API in MoonBit is, and a
/// library that flips the convention at its own boundary buys one off-by-one per
/// caller. `end` of `None` means "to the end of the object".
pub(all) struct Range {
  start : Int64
  end : Int64?
} derive(Eq, Debug)

///|
/// From `start` to the end.
pub fn Range::from(start : Int64) -> Range {
  { start, end: None, }
}

///|
/// `[start, end)`.
pub fn Range::between(start : Int64, end : Int64) -> Range {
  { start, end: Some(end), }
}

///|
/// The first `n` bytes.
pub fn Range::prefix(n : Int64) -> Range {
  { start: 0L, end: Some(n), }
}

///|
/// Where this range lands in an object of `size` bytes, as `(offset, length)`.
///
/// `None` means `RangeNotSatisfied`: the range starts before zero, or past the
/// end. An end beyond the object clamps rather than failing, which is what HTTP
/// range semantics do and what a caller asking for "the next 4KB" wants.
pub fn Range::resolve(self : Range, size : Int64) -> (Int64, Int64)? {
  guard self.start >= 0L && self.start <= size else { return None }
  let end = match self.end {
    None => size
    Some(e) => if e > size { size } else { e }
  }
  guard end >= self.start else { return None }
  Some((self.start, end - self.start))
}

///|
pub(all) struct ReadOptions {
  range : Range?
} derive(Eq, Debug)

///|
pub fn ReadOptions::default() -> ReadOptions {
  { range: None, }
}

///|
pub(all) struct WriteOptions {
  content_type : String?
  /// Append to what is there instead of replacing it. Creates when absent.
  append : Bool
  /// Fail with `AlreadyExists` rather than overwrite.
  if_not_exists : Bool
} derive(Eq, Debug)

///|
pub fn WriteOptions::default() -> WriteOptions {
  { content_type: None, append: false, if_not_exists: false, }
}

///|
pub(all) struct ListOptions {
  /// Every descendant, rather than the immediate children.
  recursive : Bool
  /// At most this many entries.
  limit : Int?
  /// Resume: only entries strictly after this path, in the ascending order
  /// `list` always answers in.
  start_after : String?
} derive(Eq, Debug)

///|
pub fn ListOptions::default() -> ListOptions {
  { recursive: false, limit: None, start_after: None, }
}

///|
pub(all) struct DeleteOptions {
  /// Delete a directory and everything under it.
  recursive : Bool
} derive(Eq, Debug)

///|
pub fn DeleteOptions::default() -> DeleteOptions {
  { recursive: false, }
}
