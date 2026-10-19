// What a conformance run produced.

///|
/// One check, and what became of it.
///
/// A check that did not run is not a check that passed: `skipped` names the
/// capability the backend does not declare, so a report reads as "17 passed, 3
/// skipped because this store has no append" rather than as twenty greens.
pub(all) struct Check {
  name : String
  /// The capability it needed, when the backend does not have it.
  skipped : String?
  /// What went wrong, when something did.
  failure : String?
} derive(Eq, Debug)

///|
pub fn Check::is_ok(self : Check) -> Bool {
  self.failure is None
}

///|
/// The outcome of a whole run.
struct Report {
  checks : Array[Check]
}

///|
pub fn Report::checks(self : Report) -> Array[Check] {
  self.checks
}

///|
pub fn Report::is_ok(self : Report) -> Bool {
  self.checks.iter().all(check => check.is_ok())
}

///|
pub fn Report::passed(self : Report) -> Int32 {
  self.checks.filter(c => c.failure is None && c.skipped is None).length()
}

///|
pub fn Report::skipped(self : Report) -> Int32 {
  self.checks.filter(c => c.skipped is Some(_)).length()
}

///|
pub fn Report::failures(self : Report) -> Array[Check] {
  self.checks.filter(c => c.failure is Some(_))
}

///|
pub impl Show for Report with fn output(self, logger) {
  let failures = self.failures()
  logger.write_string(
    "\{self.passed()} passed, \{self.skipped()} skipped, \{failures.length()} failed",
  )
  for check in failures {
    logger.write_string("\n  FAIL \{check.name}")
    if check.failure is Some(why) {
      logger.write_string(": \{why}")
    }
  }
  for check in self.checks {
    if check.skipped is Some(why) {
      logger.write_string("\n  skip \{check.name} (no \{why})")
    }
  }
}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Check with Eq::{not_equal, equal}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Check with Debug::{to_repr}

///|
pub extend Report with Show::{to_string}

///|
#deprecated(skip_current_package=true)
#doc(hidden)
pub extend Report with Show::{output}
