#!/usr/bin/env bash
# Fails when a module imports a Glint module it is not allowed to depend on.
# Dependencies point inward toward GlintCore; this mirrors the module table in the PRD.
set -euo pipefail
cd "$(dirname "$0")/.."

allowed() {
  case "$1" in
    GlintCore)        echo "" ;;
    GlintExtractors)  echo "GlintCore" ;;
    GlintEmbedding)   echo "GlintCore" ;;
    GlintStore)       echo "GlintCore" ;;
    GlintSearch)      echo "GlintCore GlintStore" ;;
    GlintIndexer)     echo "GlintCore GlintExtractors GlintEmbedding GlintStore" ;;
    GlintLicensing)   echo "GlintCore" ;;
    GlintTelemetry)   echo "GlintCore" ;;
    GlintUI)          echo "GlintCore GlintSearch GlintLicensing" ;;
    GlintLocalAPI)    echo "GlintCore GlintSearch" ;;
    GlintMCP)         echo "" ;;
    GlintMCPTool)     echo "GlintMCP" ;;
    GlintLicenseTool) echo "GlintCore GlintLicensing" ;;
    GlintEval)        echo "GlintCore GlintExtractors GlintEmbedding GlintStore GlintSearch GlintIndexer" ;;
    GlintApp)         echo "*" ;;
    *)                echo "UNKNOWN" ;;
  esac
}

status=0
for dir in Sources/*/; do
  module="$(basename "$dir")"
  permitted="$(allowed "$module")"
  if [[ "$permitted" == "UNKNOWN" ]]; then
    echo "✗ $module is not in the module table; add it to scripts/check_imports.sh"
    status=1
    continue
  fi
  [[ "$permitted" == "*" ]] && continue
  while IFS=: read -r file _ line; do
    imported="$(sed -E 's/^[[:space:]]*(@testable[[:space:]]+)?(public[[:space:]]+|internal[[:space:]]+)?import[[:space:]]+([A-Za-z0-9_]+).*/\3/' <<<"$line")"
    if [[ " $permitted " != *" $imported "* ]]; then
      echo "✗ $file imports $imported, which $module may not depend on"
      status=1
    fi
  done < <(grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?(public[[:space:]]+|internal[[:space:]]+)?import[[:space:]]+Glint' "$dir" || true)
done

[[ $status -eq 0 ]] && echo "✓ Module boundaries respected"
exit $status
