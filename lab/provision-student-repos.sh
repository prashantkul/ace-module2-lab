#!/usr/bin/env bash
# Batch-provision student repos for the CodeMender lab (keyless / WIF design).
#
# With WIF there is NO secret to distribute — students on personal GitHub
# accounts can fully self-serve (paste 3 variables, flip workflow permissions,
# run publish-cm-release.sh). Use THIS script when the instructor controls the
# repos anyway (GitHub Classroom / org) and wants to do it in one sweep.
#
# For each repo it:
#   1. Sets the three WIF repo VARIABLES (GCP_WIF_PROVIDER, GCP_SA_EMAIL,
#      GCP_QUOTA_PROJECT) — copied from a template repo you already configured.
#   2. Publishes the `cm` binary release (releases don't copy on fork/template).
#   3. Sets workflow permissions to read/write + "allow PR creation".
#   4. Verifies all three and prints a summary.
#
# GCP-side admission is separate: each repo also needs its roster IAM binding —
# run lab/wif-add-students.sh with the same repo list.
#
# Usage:
#   ./lab/provision-student-repos.sh -b ./cm-linux owner/repo1 [owner/repo2 ...]
#   ./lab/provision-student-repos.sh -b ./cm-linux -f repos.txt
#
# Options:
#   -t OWNER/REPO   Template repo to copy the three WIF variables from
#                   (default: prashantkul/ace-module2-lab).
#   -b FILE         cm-linux binary for the release (required unless --skip-release).
#   -f FILE         File listing target repos, one <owner>/<repo> per line
#                   ('#' comments and blank lines ignored).
#   --skip-release  Don't publish the cm release.
#
# Requires: gh authenticated with ADMIN access to every target repo, python3.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEMPLATE="prashantkul/ace-module2-lab"
CM_BIN=""
REPOS_FILE=""
SKIP_RELEASE=0
REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TEMPLATE="${2:-}"; shift 2 ;;
    -b) CM_BIN="${2:-}"; shift 2 ;;
    -f) REPOS_FILE="${2:-}"; shift 2 ;;
    --skip-release) SKIP_RELEASE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) REPOS+=("$1"); shift ;;
  esac
done

# ---- validate inputs before touching anything remote ----------------------
fail=0
if [[ "$SKIP_RELEASE" -eq 0 ]]; then
  if [[ -z "$CM_BIN" ]]; then
    echo "error: -b <cm-linux> is required (or pass --skip-release)" >&2; fail=1
  elif [[ ! -f "$CM_BIN" ]]; then
    echo "error: cm binary not found: $CM_BIN" >&2; fail=1
  fi
fi

if [[ -n "$REPOS_FILE" ]]; then
  if [[ ! -f "$REPOS_FILE" ]]; then
    echo "error: repos file not found: $REPOS_FILE" >&2; fail=1
  else
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] && REPOS+=("$line")
    done < "$REPOS_FILE"
  fi
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "error: no target repos given (positional args and/or -f file)" >&2; fail=1
fi
[[ "$fail" -ne 0 ]] && exit 2

# ---- pull the three WIF values from the template repo ---------------------
echo ">> reading WIF variables from template $TEMPLATE"
declare -A WIF
for V in GCP_WIF_PROVIDER GCP_SA_EMAIL GCP_QUOTA_PROJECT; do
  WIF[$V]=$(gh variable get "$V" --repo "$TEMPLATE" --json value --jq .value 2>/dev/null || true)
  if [[ -z "${WIF[$V]}" ]]; then
    echo "error: variable $V not set on $TEMPLATE — run lab/setup-wif.sh first" >&2
    exit 1
  fi
  echo "   $V = ${WIF[$V]}"
done

echo
echo "Provisioning ${#REPOS[@]} repo(s) — no secrets involved anywhere."
echo

declare -A RESULT
overall=0

for R in "${REPOS[@]}"; do
  echo "=============================================================="
  echo ">> $R"
  ok=1

  # -- 1. the three WIF variables --------------------------------------------
  for V in GCP_WIF_PROVIDER GCP_SA_EMAIL GCP_QUOTA_PROJECT; do
    if ! gh variable set "$V" --repo "$R" --body "${WIF[$V]}"; then
      echo "   variable $V: FAILED (need admin on $R?)"; ok=0
    fi
  done
  [[ "$ok" -eq 1 ]] && echo "   WIF variables: set"

  # -- 2. cm release ----------------------------------------------------------
  if [[ "$SKIP_RELEASE" -eq 0 ]]; then
    if "$SCRIPT_DIR/publish-cm-release.sh" "$R" "$CM_BIN" >/dev/null; then
      echo "   cm release: published"
    else
      echo "   cm release: FAILED"; ok=0
    fi
  fi

  # -- 3. workflow permissions ------------------------------------------------
  if gh api -X PUT "repos/$R/actions/permissions/workflow" \
       -f default_workflow_permissions=write \
       -F can_approve_pull_request_reviews=true >/dev/null; then
    echo "   workflow perms: write + PR creation"
  else
    echo "   workflow perms: FAILED"; ok=0
  fi

  # -- 4. verify ----------------------------------------------------------------
  if [[ "$ok" -eq 1 ]]; then
    v_vars=$(gh variable list --repo "$R" --json name --jq '.[].name' 2>/dev/null \
               | grep -cE '^(GCP_WIF_PROVIDER|GCP_SA_EMAIL|GCP_QUOTA_PROJECT)$' || true)
    v_perms=$(gh api "repos/$R/actions/permissions/workflow" \
                --jq 'select(.default_workflow_permissions=="write" and .can_approve_pull_request_reviews==true) | "ok"' 2>/dev/null || true)
    v_rel="ok"
    if [[ "$SKIP_RELEASE" -eq 0 ]]; then
      v_rel=$(gh release view "${CM_RELEASE_TAG:-cm-cli-v0.2.0}" --repo "$R" \
                --json assets --jq '.assets[].name' 2>/dev/null | grep -cx 'cm-linux' || true)
      [[ "$v_rel" == "1" ]] && v_rel="ok" || v_rel=""
    fi
    if [[ "$v_vars" == "3" && "$v_perms" == "ok" && "$v_rel" == "ok" ]]; then
      echo "   verify: all green"
    else
      echo "   verify: MISMATCH (vars=$v_vars/3 perms=${v_perms:-no} release=${v_rel:-no})"; ok=0
    fi
  fi

  if [[ "$ok" -eq 1 ]]; then RESULT["$R"]="OK"; else RESULT["$R"]="FAILED"; overall=1; fi
done

echo
echo "================== summary =================="
for R in "${REPOS[@]}"; do
  printf '  %-8s %s\n' "${RESULT[$R]}" "$R"
done
echo "============================================="
echo "Remember the GCP-side roster (same repo list):"
echo "  ./lab/wif-add-students.sh ${WIF[GCP_QUOTA_PROJECT]} ${REPOS[*]}"
if [[ "$overall" -ne 0 ]]; then
  echo "Some repos FAILED — every step is idempotent, fix and re-run." >&2
fi
exit "$overall"
