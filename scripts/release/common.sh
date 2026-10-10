#!/usr/bin/env bash
# Shared helpers for the release scripts. Source, don't run.
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

require_env() {
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "set $name (see scripts/release/README.md)"
  done
}

require_app() {
  [[ -d "${1:-}" && -f "$1/Contents/Info.plist" ]] || die "pass the path to a built Glint.app"
}

app_version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }
app_build() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist"; }

# Sparkle's command-line tools ship inside the SwiftPM artifact (or set SPARKLE_BIN).
sparkle_tool() {
  local tool="$1" dir="${SPARKLE_BIN:-}"
  if [[ -z "$dir" ]]; then
    dir="$(find "$RELEASE_ROOT/.build/artifacts" -type d -path '*Sparkle/bin' 2>/dev/null | head -1)"
  fi
  [[ -x "$dir/$tool" ]] || die "Sparkle's $tool not found; run 'swift package resolve' or set SPARKLE_BIN"
  echo "$dir/$tool"
}
