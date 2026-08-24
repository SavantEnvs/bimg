#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral known-answer oracle for bimg's texturec.
#
# AUTHORED ORACLE: upstream bimg ships NO test suite (its CI only builds texturec and runs
# `--version`), so this is a hand-written known-answer test over the texturec conversion
# pipeline (decode -> transform -> encode). It asserts OUTPUT CONTENT (magic bytes + header
# dimensions of the produced textures), never just exit codes, so a neutered exit(0) binary
# fails every case. Runs the unsanitized /mayhem/texturec-oracle built by mayhem/build.sh.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

BIN=/mayhem/texturec-oracle
[ -x "$BIN" ] || { echo "FATAL: $BIN missing — mayhem/build.sh should have built it" >&2; emit_ctrf texturec-kat 0 1; exit 1; }

IN="$SRC/mayhem/testdata/known.png"   # committed deterministic 8x8 RGB gradient
OUT=/tmp/texturec-test
rm -rf "$OUT"; mkdir -p "$OUT"

pass=0; fail=0
check() { # <name> <cmd...>
  local name="$1"; shift
  if "$@"; then pass=$((pass+1)); echo "PASS: $name"; else fail=$((fail+1)); echo "FAIL: $name"; fi
}

# T1: --version prints the tool banner (a neutered binary prints nothing).
t_version() { "$BIN" --version 2>/dev/null | grep -q "bgfx texture compiler tool"; }

# T2: PNG -> PNG round trip preserves the 8x8 dimensions (parse the output IHDR).
t_png() {
  "$BIN" -f "$IN" -o "$OUT/out.png" >/dev/null 2>&1 || return 1
  python3 - "$OUT/out.png" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
assert d[12:16] == b"IHDR", "no IHDR"
w, h = struct.unpack(">II", d[16:24])
assert (w, h) == (8, 8), f"dims {w}x{h} != 8x8"
PY
}

# T3: PNG -> KTX with BC1 encode: KTX magic + 8x8 dims in the header.
t_ktx() {
  "$BIN" -f "$IN" -o "$OUT/out.ktx" -t BC1 >/dev/null 2>&1 || return 1
  python3 - "$OUT/out.ktx" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:12] == b"\xabKTX 11\xbb\r\n\x1a\n", "not a KTX"
w, h = struct.unpack("<II", d[36:44])
assert (w, h) == (8, 8), f"dims {w}x{h} != 8x8"
PY
}

# T4: mip-map generation: 8x8 with -m must report numberOfMipmapLevels == 4 in the KTX header.
t_mips() {
  "$BIN" -f "$IN" -o "$OUT/mips.ktx" -t RGBA8 -m >/dev/null 2>&1 || return 1
  python3 - "$OUT/mips.ktx" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:12] == b"\xabKTX 11\xbb\r\n\x1a\n", "not a KTX"
(mips,) = struct.unpack("<I", d[56:60])
assert mips == 4, f"mip levels {mips} != 4"
PY
}

# T5: DDS output: magic + 8x8 dims in the DDS header.
t_dds() {
  "$BIN" -f "$IN" -o "$OUT/out.dds" -t BC1 >/dev/null 2>&1 || return 1
  python3 - "$OUT/out.dds" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:4] == b"DDS ", "not a DDS"
h, w = struct.unpack("<II", d[12:20])
assert (w, h) == (8, 8), f"dims {w}x{h} != 8x8"
PY
}

# T6: garbage input must be REJECTED (nonzero exit, no output file).
t_reject() {
  printf 'not an image at all' > "$OUT/garbage.bin"
  if "$BIN" -f "$OUT/garbage.bin" -o "$OUT/bad.png" >/dev/null 2>&1; then return 1; fi
  [ ! -s "$OUT/bad.png" ]
}

check "version banner"        t_version
check "png->png dims"         t_png
check "png->ktx bc1 dims"     t_ktx
check "mip levels"            t_mips
check "png->dds dims"         t_dds
check "garbage rejected"      t_reject

emit_ctrf texturec-kat "$pass" "$fail"
