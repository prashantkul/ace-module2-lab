#!/usr/bin/env bash
# Provision student repos for the CodeMender CI/CD Guardrail lab — WITHOUT
# ever handing the service-account key to students.
#
# For each repo this script:
#   1. Sets the GCP_SA_KEY Actions secret (write-only on GitHub: students can
#      see that the secret EXISTS, never its value).
#   2. Publishes the `cm` binary as the cm-cli release (via publish-cm-release.sh;
#      releases don't copy on fork/template, so every repo needs its own).
#   3. Sets workflow permissions to read/write + "allow PR creation" via the
#      API — the two Settings toggles the remediation PR step needs.
#   4. Verifies all three, and prints a summary table.
#
# Usage:
#   ./lab/provision-student-repos.sh -k cm-ci-key.json -b ./cm-linux owner/repo1 [owner/repo2 ...]
#   ./lab/provision-student-repos.sh -k cm-ci-key.json -b ./cm-linux -f repos.txt
#
# Options:
#   -k FILE   Service-account JSON key (required). Never committed, never shown.
#   -b FILE   cm-linux binary to publish as the release asset
#             (required unless --skip-release).
#   -f FILE   File listing target repos, one <owner>/<repo> per line
#             ('#' comments and blank lines ignored). May be combined with
#             positional repo args.
#   --skip-release   Don't publish the cm release (e.g. already done).
#
# Requires: gh authenticated as a user with ADMIN access to every target repo
# (org owner for GitHub Classroom / org repos), python3.
#
# The instructor creates the SA + key once — see INSTRUCTOR.md §2a. After the
# course, delete the key:  gcloud iam service-accounts keys delete ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY_FILE=""
CM_BIN=""
REPOS_FILE=""
SKIP_RELEASE=0
REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k) KEY_FILE="${2:-}"; shift 2 ;;
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
if [[ -z "$KEY_FILE" ]]; then
  echo "error: -k <key.json> is required" >&2; fail=1
elif [[ ! -s "$KEY_FILE" ]]; then
  echo "error: key file missing or EMPTY: $KEY_FILE (an empty secret fails the pipeline's credential check)" >&2; fail=1
elif ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("type")=="service_account", f"type={d.get(\"type\")!r}, expected service_account"
print(f"key OK: {d[\"client_email\"]} (project {d[\"project_id\"]})")
' "$KEY_FILE"; then
  echo "error: $KEY_FILE is not a valid service-account key JSON" >&2; fail=1
fi

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

echo
echo "Provisioning ${#REPOS[@]} repo(s). The key value is sent write-only to"
echo "GitHub's secret store — it is never printed and students cannot read it back."
echo

declare -A RESULT
overall=0

for R in "${REPOS[@]}"; do
  echo "=============================================================="
  echo ">> $R"
  ok=1

  # -- 1. secret (write-only) -----------------------------------------------
  if gh secret set GCP_SA_KEY --repo "$R" < "$KEY_FILE"; then
    echo "   secret GCP_SA_KEY: set"
  else
    echo "   secret GCP_SA_KEY: FAILED (need admin on $R?)"; ok=0
  fi

  # -- 2. cm release ---------------------------------------------------------
  if [[ "$SKIP_RELEASE" -eq 0 ]]; then
    if "$SCRIPT_DIR/publish-cm-release.sh" "$R" "$CM_BIN" >/dev/null; then
      echo "   cm release: published"
    else
      echo "   cm release: FAILED"; ok=0
    fi
  fi

  # -- 3. workflow permissions (the two Settings toggles, via API) -----------
  if gh api -X PUT "repos/$R/actions/permissions/workflow" \
       -f default_workflow_permissions=write \
       -F can_approve_pull_request_reviews=true >/dev/null; then
    echo "   workflow perms: write + PR creation"
  else
    echo "   workflow perms: FAILED"; ok=0
  fi

  # -- 4. verify --------------------------------------------------------------
  if [[ "$ok" -eq 1 ]]; then
    v_secret=$(gh secret list --repo "$R" --json name --jq '.[].name' 2>/dev/null | grep -cx 'GCP_SA_KEY' || true)
    v_perms=$(gh api "repos/$R/actions/permissions/workflow" \
                --jq 'select(.default_workflow_permissions=="write" and .can_approve_pull_request_reviews==true) | "ok"' 2>/dev/null || true)
    v_rel="ok"
    if [[ "$SKIP_RELEASE" -eq 0 ]]; then
      v_rel=$(gh release view "${CM_RELEASE_TAG:-cm-cli-v0.2.0}" --repo "$R" \
                --json assets --jq '.assets[].name' 2>/dev/null | grep -cx 'cm-linux' || true)
      [[ "$v_rel" == "1" ]] && v_rel="ok" || v_rel=""
    fi
    if [[ "$v_secret" == "1" && "$v_perms" == "ok" && "$v_rel" == "ok" ]]; then
      echo "   verify: all green"
    else
      echo "   verify: MISMATCH (secret=$v_secret perms=${v_perms:-no} release=${v_rel:-no})"; ok=0
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
if [[ "$overall" -eq 0 ]]; then
  echo "All repos provisioned. Students never saw the key — remind them NOT to"
  echo "commit any key file if one circulates, and delete the SA key after the course."
else
  echo "Some repos FAILED — fix (usually: missing admin permission) and re-run;"
  echo "every step is idempotent, so re-running is safe." >&2
fi
exit "$overall"
