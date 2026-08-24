#!/usr/bin/env bash
#
# mayhem/build.sh — build the bimg image-decode path as fuzz targets.
#
#   /mayhem/texturec         in-process libFuzzer harness over bimg::imageParse (the same
#                            decode path the `texturec` CLI drives) — the Mayhem fuzz target.
#                            Also replays a crash file directly: `/mayhem/texturec <file>`.
#   /mayhem/texturec-oracle  clean, unsanitized real `texturec` CLI for mayhem/test.sh's KAT.
#
# The raw file-input `texturec` CLI was unproductive under Mayhem once built with the required
# ASan/UBSan (analysis phases abort with 0 edges); rule 5 of the port contract endorses
# converting such a target to an in-process libFuzzer harness over the SAME code path.
#
# bimg builds with GENie (from the sibling `bx` repo, baked into the image at $BX_DIR by
# mayhem/Dockerfile) which emits GNU makefiles; the generated makefiles append the user
# CC/CXX/CFLAGS/CXXFLAGS/LDFLAGS, so we inject sanitizer + coverage + DWARF flags there.
# Fully offline (no network) — bx is pre-baked.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${BX_DIR:=/opt/bx}"
export SANITIZER_FLAGS DEBUG_FLAGS LIB_FUZZING_ENGINE CC CXX MAYHEM_JOBS BX_DIR

cd "$SRC"

GENIE="$BX_DIR/tools/bin/linux/genie"
PROJ=".build/projects/gmake-linux-clang"
BIN=".build/linux64_clang/bin"
LIBS="$BIN/libbimg_decodeRelease.a $BIN/libbimgRelease.a $BIN/libbxRelease.a"
INCS="-std=c++20 -DBX_CONFIG_DEBUG=0 -Iinclude -I$BX_DIR/include"
HARNESS="mayhem/texturec/texturec_fuzz.cpp"

build_bimg() {
  # $1 extra C/CXX flags  $2 extra LDFLAGS
  rm -rf .build
  "$GENIE" --with-tools --gcc=linux-clang gmake >/dev/null
  make -C "$PROJ" config=release64 -j"$MAYHEM_JOBS" \
    CC="$CC" CXX="$CXX" \
    CFLAGS="$1" CXXFLAGS="$1" LDFLAGS="$2" \
    bx bimg bimg_decode texturec
}

# 1) Sanitized + coverage-instrumented static libs, then link the in-process libFuzzer harness.
#    fuzzer-no-link adds SanitizerCoverage to the bimg code under test; the harness links the
#    libFuzzer runtime with -fsanitize=fuzzer.
build_bimg "$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" "$SANITIZER_FLAGS"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INCS $LIB_FUZZING_ENGINE \
  "$HARNESS" $LIBS -lpthread -ldl -lm -o /mayhem/texturec

# 2) Oracle: clean unsanitized real texturec CLI for the behavioral KAT in test.sh.
build_bimg "$DEBUG_FLAGS" ""
cp "$BIN/texturecRelease" /mayhem/texturec-oracle

ls -la /mayhem/texturec /mayhem/texturec-oracle
