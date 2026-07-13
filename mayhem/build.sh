#!/usr/bin/env bash
#
# mayhem/build.sh — build LibreDWG's llvmfuzz harness (libFuzzer + standalone) AND its unit-test
# suite. Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem == $SRC.
#
# Layout produced:
#   /mayhem/llvmfuzz              libFuzzer target (SanitizerCoverage + ASan/UBSan)   <- the Mayhem target
#   /mayhem/llvmfuzz-standalone   run-once file-input reproducer (same code path)
#   $SRC/build-tests/...          the project's unit tests, built with NORMAL flags for mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Offline-safe version stamp so autoreconf/git-version-gen never touches the network.
echo "0.14.8421" > .tarball-version

# jsmn (single MIT header, a git submodule upstream) is vendored under mayhem/vendor/ so the build
# never touches the network even when the checkout has only the submodule gitlink.
mkdir -p jsmn
[ -f jsmn/jsmn.h ] || cp mayhem/vendor/jsmn.h jsmn/jsmn.h

autoreconf -fi -I m4

CONFIGURE_COMMON=(--disable-shared --disable-bindings --enable-release --disable-python --disable-gcov)

# Both builds are VPATH (out-of-tree) so the source dir stays pristine and re-running this script is
# idempotent (rm -rf + rebuild of each build dir; no in-tree configure state to collide with).

# 1) TEST build with the project's NORMAL flags, in its own VPATH tree so test.sh only RUNS it and
#    never false-fails on benign UB from the halting sanitizers.
rm -rf build-tests
mkdir -p build-tests
( cd build-tests && ../configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" "${CONFIGURE_COMMON[@]}" )
make -j"$MAYHEM_JOBS" -C build-tests/src
make -j"$MAYHEM_JOBS" -C build-tests/test/unit-testing check-prep

# 2) FUZZ build: instrument the WHOLE library with SanitizerCoverage (-fsanitize=fuzzer-no-link) plus
#    ASan+UBSan. -fsanitize=fuzzer-no-link gives libFuzzer coverage feedback over the library code
#    path (not just the harness).
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"
rm -rf build-fuzz
mkdir -p build-fuzz
( cd build-fuzz && ../configure CC="$CC" CFLAGS="$FUZZ_CFLAGS" "${CONFIGURE_COMMON[@]}" )
make -j"$MAYHEM_JOBS" -C build-fuzz/src

LIB="$SRC/build-fuzz/src/.libs/libredwg.a"
[ -f "$LIB" ] || { echo "ERROR: $LIB not built" >&2; exit 1; }

# libFuzzer target (the Mayhem target: name "llvmfuzz").
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I"$SRC/include" -I"$SRC/src" -I"$SRC/build-fuzz/src" \
    -c "$SRC/examples/llvmfuzz.c" -o /tmp/llvmfuzz.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE /tmp/llvmfuzz.o "$LIB" -o /mayhem/llvmfuzz

# Standalone (non-fuzzer) reproducer over the same LLVMFuzzerTestOneInput code path.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -DSTANDALONE -I"$SRC/include" -I"$SRC/src" -I"$SRC/build-fuzz/src" \
    "$SRC/examples/llvmfuzz.c" "$LIB" -o /mayhem/llvmfuzz-standalone

echo "build.sh: done — /mayhem/llvmfuzz, /mayhem/llvmfuzz-standalone, build-tests/ unit tests"
