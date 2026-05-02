#!/usr/bin/env bash
# 把 marked_text_probe.swift 编译成独立 binary 并运行。
# 这样辅助功能权限可以直接挂在这个固定路径的 binary 上，
# 而不是动态 swift 解释器（每次都被视作新进程）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/marked_text_probe.swift"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/marked_text_probe"

mkdir -p "$OUT_DIR"
echo "Compiling $SRC → $OUT"
swiftc -O \
  -framework AppKit \
  -framework ApplicationServices \
  "$SRC" \
  -o "$OUT"
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true

echo
echo "Running: $OUT"
echo "If you see NO_FOCUSED_ELEMENT, add this exact path to:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  $OUT"
echo
exec "$OUT"
