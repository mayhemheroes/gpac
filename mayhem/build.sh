#!/usr/bin/env bash
#
# mayhem/build.sh — build gpac's ISOBMFF/MP4 parser fuzz harness `fuzz_parse`
# (the OSS-Fuzz target: exercises gf_isom_open_file + the isomedia box parser).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (linked into the libFuzzer harness)
#   SANITIZER_FLAGS     ASan + UBSan, both HALTing (-fno-sanitize-recover)
#   STANDALONE_FUZZ_MAIN  LLVM run-once driver (non-fuzzer reproducer main)
#   SRC                 /mayhem (the repo source)
#
# gpac specifics:
#  * Custom ./configure + make. We build LEAN and OFFLINE with `--isomedia-only` (keeps exactly
#    the MP4/ISOBMFF parse path the harness uses, drops every heavy/optional dep) plus
#    `--static-build` so libgpac is a static .a we link into the harness. NB: NOT `--static-bin`
#    — that adds `-static` to every link/probe, which the ASan runtime cannot link fully static
#    ("undefined reference to _DYNAMIC"), breaking configure's zlib probe. --static-build links
#    libgpac statically while leaving libc/libz dynamic, which is what the harness needs.
#  * gpac honours $CFLAGS/$LDFLAGS via --extra-cflags/--extra-ldflags, so $SANITIZER_FLAGS reaches
#    the PROJECT compile (the fuzzed code is instrumented, not just the harness).
#  * The harness source (fuzz_parse.c) is the OSS-Fuzz one, vendored under mayhem/ (additive);
#    upstream's build pulled it from the gpac/testsuite repo at build time — we ship it so the
#    build is self-contained and offline.
#
# TWO builds, in this order (they share bin/gcc + config.mak, so they cannot coexist):
#   1) the LEAN, SANITIZED fuzz build (--static-build --isomedia-only) -> /mayhem/fuzz_parse[-standalone].
#      These link libgpac STATICALLY, so the emitted binaries survive the `make distclean` below.
#   2) a SEPARATE NORMAL-flags build configured with --unittests (gpac's in-tree assertion-based unit
#      framework: unittests/tests.c + the src/**/unittests/*.c suites). `make unit_tests` builds the
#      runner at unittests/build/bin/gcc/unittests (a shared-lib build: libgpac.so is copied next to it)
#      and runs unittests/launch.sh. mayhem/test.sh RUNS that binary as the PATCH oracle — it asserts
#      real behaviour (assert_equal_*), not exit codes, and prints "Tests passed/failed", "Checks
#      passed/failed". Default features are enough for the suites (XML parser, DASH MPD/SCTE35, dec_cc
#      closed-caption decoder, gf_sys_word_match); --disable-dvb4linux for the same reason as the fuzz
#      build. NB: this normal build must NOT carry $SANITIZER_FLAGS — it is the clean test oracle.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (overridable), with sane defaults — no if-plumbing.
# SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty value (--build-arg SANITIZER_FLAGS=)
# is honored and builds with NO sanitizers (natural crash, no ASan report).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# 1) Build the PROJECT (libgpac) lean + sanitized. --isomedia-only keeps the MP4/ISOBMFF parser
#    (the fuzzed code) and drops heavy deps; --static-bin links libgpac statically. The sanitizer
#    flags flow into the project compile via --extra-cflags/--extra-ldflags so the fuzzed code is
#    instrumented. -fsanitize=fuzzer-no-link adds libFuzzer coverage to the project objects.
# --disable-dvb4linux: the in_dvb4linux input module is auto-enabled when the kernel DVB headers
# are present (they are in the base image) but does not compile at this upstream commit and is
# irrelevant to the MP4 parser harness, so drop it.
./configure --static-build --isomedia-only --disable-dvb4linux \
    --extra-cflags="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    --extra-ldflags="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -j"$MAYHEM_JOBS" lib

GPAC_LIB="$SRC/bin/gcc/libgpac_static.a"
[ -f "$GPAC_LIB" ] || { echo "ERROR: $GPAC_LIB not built" >&2; exit 1; }

HARNESS="$SRC/mayhem/fuzz_parse.c"
INCS="-I$SRC/include -I$SRC"
# zlib is the only external lib --static-bin/--isomedia-only leaves linked in libgpac.
LINK_LIBS="$GPAC_LIB -lz -lm -lpthread"
DEFS="-DGPAC_HAVE_CONFIG_H"

# 2a) libFuzzer harness (the Mayhem fuzzing binary).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $DEFS \
    "$HARNESS" $INCS $LINK_LIBS \
    -o /mayhem/fuzz_parse

# 2b) Standalone (non-fuzzer) reproducer: run-once driver, no libFuzzer runtime. fuzz_parse.c is a
#     C harness, so it links the C driver directly. Respects $SANITIZER_FLAGS (empty -> clean repro).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $DEFS \
    "$STANDALONE_FUZZ_MAIN" "$HARNESS" $INCS $LINK_LIBS \
    -o /mayhem/fuzz_parse-standalone

echo "built: /mayhem/fuzz_parse (libFuzzer), /mayhem/fuzz_parse-standalone (reproducer)"

# 3) Build the OTHER FOUR OSS-Fuzz harnesses (fuzz_m2ts_probe, fuzz_probe_analyze, fuzz_route,
#    fuzz_scene). These need features the LEAN --isomedia-only build above drops:
#      * fuzz_m2ts_probe  -> gf_m2ts_probe_file (MPEG-2 TS demux, src/media_tools/mpegts.c)
#      * fuzz_probe_analyze, fuzz_route -> the gf_fs_* filter session (src/filter_core + filters)
#      * fuzz_scene       -> the BIFS + LASeR scene decoders (src/bifs, src/laser)
#    So they are built against a SEPARATE, FULL-FEATURE libgpac: a plain `--static-build` (NO
#    --isomedia-only) — exactly the feature set OSS-Fuzz's build.sh uses. Sanitizer flags still
#    flow into the project compile via --extra-cflags/--extra-ldflags so the fuzzed code is
#    instrumented. This build shares bin/gcc + config.mak with the lean build above, so distclean
#    the tree first (the fuzz_parse[-standalone] binaries are already emitted to /mayhem and link
#    libgpac STATICALLY, so they are unaffected by the distclean).
make distclean >/dev/null 2>&1 || true

./configure --static-build --disable-dvb4linux \
    --extra-cflags="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    --extra-ldflags="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -j"$MAYHEM_JOBS" lib

GPAC_LIB="$SRC/bin/gcc/libgpac_static.a"
[ -f "$GPAC_LIB" ] || { echo "ERROR: full-feature $GPAC_LIB not built" >&2; exit 1; }

# The full build pulls in TLS-using code (DASH/HTTP/route), so link openssl too — matches OSS-Fuzz
# (-lssl -lcrypto). zlib/pthread/m as before. libssl-dev/zlib1g-dev ship in the base image.
FULL_LINK_LIBS="$GPAC_LIB -lz -lm -lpthread -lssl -lcrypto"

for name in fuzz_m2ts_probe fuzz_probe_analyze fuzz_route fuzz_scene; do
    HARNESS="$SRC/mayhem/$name.c"
    [ -f "$HARNESS" ] || { echo "ERROR: harness $HARNESS missing" >&2; exit 1; }

    # libFuzzer harness (the Mayhem fuzzing binary).
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $DEFS \
        "$HARNESS" $INCS $FULL_LINK_LIBS \
        -o "/mayhem/$name"

    # Standalone (non-fuzzer) reproducer: run-once driver, no libFuzzer runtime. These are C
    # harnesses, so they link the C driver directly. Respects $SANITIZER_FLAGS.
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $DEFS \
        "$STANDALONE_FUZZ_MAIN" "$HARNESS" $INCS $FULL_LINK_LIBS \
        -o "/mayhem/$name-standalone"

    echo "built: /mayhem/$name (libFuzzer), /mayhem/$name-standalone (reproducer)"
done

# 4) Build the TEST ORACLE: gpac's in-tree unit-test framework, with NORMAL (un-sanitized) flags.
#    Separate from the fuzz build above — they share bin/gcc + config.mak, so distclean the tree
#    first (the fuzz binaries are already emitted to /mayhem and link libgpac statically, so they
#    are unaffected). Then configure with --unittests and `make unit_tests`, which builds the runner
#    at unittests/build/bin/gcc/unittests (next to its own libgpac.so) and executes it via launch.sh.
#    mayhem/test.sh re-runs that binary as the oracle; building it here means the image bakes a ready
#    runner and the build fails fast if the unit suite can't even compile/link.
make distclean >/dev/null 2>&1 || true

# --unittests enables gpac's assertion-based unit framework. Default features (no --isomedia-only,
# no sanitizers) so the filter/media_tools/utils suites link. --disable-dvb4linux: the auto-detected
# in_dvb4linux module doesn't compile at this commit (kernel DVB headers present in the base image).
./configure --unittests --disable-dvb4linux
make -j"$MAYHEM_JOBS" lib
# `make unit_tests` builds the runner (a second, symbol-exporting build of libgpac under
# unittests/build) AND runs launch.sh. Running here is fine (build fails fast on a broken suite);
# mayhem/test.sh runs it again as the graded oracle.
make unit_tests

UT_BIN="$SRC/unittests/build/bin/gcc/unittests"
[ -x "$UT_BIN" ] || { echo "ERROR: unit-test runner $UT_BIN not built" >&2; exit 1; }
echo "built: $UT_BIN (unit-test oracle)"
