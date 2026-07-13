#!/usr/bin/env bash
#
# mayhem/test.sh — RUN nickel's OWN test suite (already compiled by
# mayhem/build.sh via `cargo test --workspace --no-run` into
# $SRC/mayhem/test-target; the runner list is $SRC/mayhem/test-bins.txt).
# This script only RUNS the prebuilt runners; it does not recompile.
#
# The suite is the full upstream workspace suite (minus py-nickel and the
# wasm-only crate): core's evaluation/typechecking/stdlib known-answer tests,
# the parser tests, the CLI integration + snapshot tests, the package-manager
# tests, and the LSP tests. Anti-reward-hack: we assert on the libtest OUTPUT
# MARKERS ("test result: ok. N passed; M failed") parsed FROM the real run, AND
# require passed>0 — a PATCH that neuters nickel to a no-op / exit(0) produces
# no marker (or 0 passed / real failures) and FAILS here (SPEC §6.3). Emits a
# CTRF summary; exits 0 iff failed==0 and passed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Some test binaries link dynamically against the toolchain's libstd — put the
# pinned toolchain's lib dir on the loader path.
if command -v rustc >/dev/null 2>&1; then
  SYSROOT="$(rustc --print sysroot)"
  export LD_LIBRARY_PATH="$SYSROOT/lib:$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib:${LD_LIBRARY_PATH:-}"
fi

BINS_FILE="$SRC/mayhem/test-bins.txt"
if [ ! -s "$BINS_FILE" ]; then
  echo "FATAL: $BINS_FILE missing/empty — build.sh should have produced it" >&2
  emit_ctrf "cargo-test" 0 1
  exit 1
fi

passed_total=0
failed_total=0
skipped_total=0
saw_marker=0

while IFS=$'\t' read -r pkgdir runner; do
  [ -n "$runner" ] || continue
  if [ ! -x "$runner" ]; then
    echo "FATAL: prebuilt test runner missing: $runner" >&2
    failed_total=$(( failed_total + 1 ))
    continue
  fi
  echo "=== running $runner (cwd $pkgdir) ==="
  # Recreate the cargo-provided package env: some tests (the CLI sigil_env
  # snapshot) read @env:CARGO_PKG_NAME, which cargo sets when running tests.
  pkgname="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$pkgdir/Cargo.toml" | head -1)"
  out="$(cd "$pkgdir" && CARGO_PKG_NAME="$pkgname" "$runner" --test-threads="$MAYHEM_JOBS" 2>&1)" && rc=0 || rc=$?
  echo "$out"
  runner_marker=0
  # Parse libtest summary: "test result: ok. 53 passed; 0 failed; 2 ignored; ..."
  while IFS= read -r line; do
    if [[ "$line" =~ test\ result:.*\ ([0-9]+)\ passed\;\ ([0-9]+)\ failed\;\ ([0-9]+)\ ignored ]]; then
      passed_total=$(( passed_total + ${BASH_REMATCH[1]} ))
      failed_total=$(( failed_total + ${BASH_REMATCH[2]} ))
      skipped_total=$(( skipped_total + ${BASH_REMATCH[3]} ))
      saw_marker=1; runner_marker=1
    fi
  done <<< "$out"
  # A runner that exits nonzero but printed no summary marker still counts as a failure.
  if [ "$rc" -ne 0 ] && [ "$runner_marker" -eq 0 ]; then
    failed_total=$(( failed_total + 1 ))
  fi
done < "$BINS_FILE"

# No summary marker at all ⇒ the binaries never ran the real suite (neutered/no-op) ⇒ FAIL.
if [ "$saw_marker" -eq 0 ]; then
  echo "FATAL: no libtest 'test result:' marker seen — suite did not run" >&2
  emit_ctrf "cargo-test" 0 1
  exit 1
fi
# Sanity floor: the suite must actually pass tests, else the oracle is vacuous.
if [ "$passed_total" -eq 0 ]; then
  echo "FATAL: 0 tests passed — oracle would be vacuous" >&2
  emit_ctrf "cargo-test" 0 $(( failed_total > 0 ? failed_total : 1 ))
  exit 1
fi

emit_ctrf "cargo-test" "$passed_total" "$failed_total" "$skipped_total"
