#!/usr/bin/env bash
#
# mayhem/build.sh — build nickel's in-process libFuzzer target as a sanitized
# binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), and pre-compile
# the workspace's OWN test suite (cargo test --no-run) so mayhem/test.sh can RUN
# it offline as the behavioral oracle.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run, so we do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Sanitizers (§6.1): the base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting).
# rustc can't consume those clang flags, but we honor the KNOB: when $SANITIZER_FLAGS
# is non-empty we instrument the Rust build with ASan (the OSS-Fuzz Rust path); an
# explicit empty `--build-arg SANITIZER_FLAGS=` yields an un-sanitized build.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so pin -Zdwarf-version=3
# for Rust code; the libfuzzer-sys cc shim is compiled by clang, so pin its DWARF too.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that `-Zsanitizer=address` links is precompiled
# with clang (DWARF-5) and ships with full debug info, which would otherwise land
# DWARF-5 compile units in the final binary and fail the DWARF < 4 gate. Strip the
# debug info from that runtime archive (a toolchain artifact, NOT project code).
# Idempotent: re-running --strip-debug on an already-stripped archive is a no-op.
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the fuzz crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Pre-compile nickel's OWN test suite for the behavioral oracle (test.sh) ──
# The workspace ships a real assertion suite: core's integration/known-answer
# tests (evaluation, typechecking, stdlib), the parser tests, the CLI snapshot
# tests, the package-manager tests, the LSP tests, etc. Compile it here — with
# the project's NORMAL flags, no sanitizer, no DWARF pins — into
# $SRC/mayhem/test-target, and record every produced test executable in
# $SRC/mayhem/test-bins.txt so mayhem/test.sh only RUNS them.
# Excluded: py-nickel (needs a Python interpreter dev environment) and
# nickel-wasm-repl (wasm-only crate) — neither carries the project's tests.
echo "=== cargo test --no-run (compile the workspace's own test suite) ==="
mkdir -p "$SRC/mayhem/test-target"
if ! env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS \
  cargo test --workspace --exclude py-nickel --exclude nickel-wasm-repl \
  --no-run --target-dir "$SRC/mayhem/test-target" \
  --message-format=json >"$SRC/mayhem/test-target/cargo-test-build.json" \
  2>"$SRC/mayhem/test-target/cargo-test-build.log"; then
  echo "ERROR: cargo test --no-run failed:" >&2
  cat "$SRC/mayhem/test-target/cargo-test-build.log" >&2
  exit 1
fi
python3 -c '
import json, sys, os
rows = []
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m.get("executable") and m.get("profile", {}).get("test"):
        # libtest binaries expect CWD = the package directory (tests read relative paths)
        pkgdir = os.path.dirname(m["manifest_path"])
        rows.append(pkgdir + "\t" + m["executable"])
print("\n".join(rows))
' < "$SRC/mayhem/test-target/cargo-test-build.json" > "$SRC/mayhem/test-bins.txt"
[ -s "$SRC/mayhem/test-bins.txt" ] || { echo "ERROR: no test executables recorded" >&2; cat "$SRC/mayhem/test-target/cargo-test-build.log" >&2; exit 1; }
echo "recorded test runners:"; cat "$SRC/mayhem/test-bins.txt"

echo "build.sh complete"
