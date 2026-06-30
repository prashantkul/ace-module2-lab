#!/usr/bin/env bash
# Publish the CodeMender `cm` binary as a Release asset on a repo, so that repo's
# CodeMender guardrail workflow can download it in CI with the built-in
# GITHUB_TOKEN (`gh release download cm-cli-v0.1.0 --pattern cm-linux`).
#
# Run this ONCE PER STUDENT REPO (GitHub does not copy releases on fork/template).
#
# Usage:
#   ./lab/publish-cm-release.sh <owner>/<repo> /path/to/cm-linux [/path/to/cm-mac]
#
# Requires: gh (authenticated with `repo` scope on the target repo).
set -euo pipefail

TAG="cm-cli-v0.1.0"
REPO="${1:-}"
CM_LINUX="${2:-}"
CM_MAC="${3:-}"

if [[ -z "$REPO" || -z "$CM_LINUX" ]]; then
  echo "usage: $0 <owner>/<repo> /path/to/cm-linux [/path/to/cm-mac]" >&2
  exit 2
fi
if [[ ! -f "$CM_LINUX" ]]; then
  echo "error: cm-linux not found at: $CM_LINUX" >&2
  exit 1
fi

# Assets are uploaded with fixed names the workflow expects: cm-linux / cm-mac.
assets=( "${CM_LINUX}#cm-linux" )
[[ -n "$CM_MAC" && -f "$CM_MAC" ]] && assets+=( "${CM_MAC}#cm-mac" )

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists on $REPO — uploading/clobbering assets."
  gh release upload "$TAG" --repo "$REPO" --clobber "${assets[@]}"
else
  echo "Creating release $TAG on $REPO."
  gh release create "$TAG" --repo "$REPO" \
    --title "CodeMender CLI v0.1.0 (lab runtime)" \
    --notes "CodeMender \`cm\` CLI for the Module 2 CI/CD Guardrail lab. Downloaded in CI via the built-in GITHUB_TOKEN." \
    "${assets[@]}"
fi

echo "Done. Assets on $REPO@$TAG:"
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name'
