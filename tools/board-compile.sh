#!/bin/bash
# Compile-only check of a sketch folder (no flashing). Usage: compile.sh <sketch_dir> [tag]
# Mirrors what App Lab does: sketch.yaml profile + arduino:zephyr:unoq. The build
# dir is kept between runs so libraries/core are only compiled once.
set -u
SRC="$1"; TAG="${2:-dev}"
W=/tmp/qtb-build/$TAG
mkdir -p "$W/build"
rm -rf "$W/sketch" "$W/rc"; mkdir -p "$W/sketch"
cp -a "$SRC"/. "$W/sketch/"
# App Lab leaves fqbn blank in sketch.yaml and injects it at build time - do the same here.
sed -i 's/^\(\s*fqbn:\).*/\1 arduino:zephyr:unoq/' "$W/sketch/sketch.yaml"
LOG="$W/compile.log"
START=$(date +%s)
arduino-cli compile --profile default --warnings default --build-path "$W/build" "$W/sketch" > "$LOG" 2>&1
RC=$?
echo "exit=$RC elapsed=$(( $(date +%s) - START ))s" >> "$LOG"
echo "$RC" > "$W/rc"
