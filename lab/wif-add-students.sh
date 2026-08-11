#!/usr/bin/env bash
# Class-roster management for the shared-project WIF rollout.
#
# One pool/provider/SA (created by setup-wif.sh) serves the whole class; each
# student is admitted by ONE IAM binding on the CI service account:
#
#   principalSet://…/attribute.repository/<their-repo>
#
# The provider's attribute condition is relaxed to "repository is named
# ace-module2-lab" (coarse filter); the per-repo IAM bindings added here are
# the actual roster — only listed repos can impersonate the SA, and removing
# a binding revokes exactly one student.
#
# Every student gets the SAME three repo variables (they are not secrets):
# this script prints them at the end for the class handout.
#
# Usage:
#   ./lab/wif-add-students.sh <gcp-project-id> <student> [<student> ...]
#   ./lab/wif-add-students.sh <gcp-project-id> -f roster.txt
#   ./lab/wif-add-students.sh <gcp-project-id> -r <student>      # revoke
#
# <student> is a GitHub username (expands to <username>/ace-module2-lab) or a
# full <owner>/<repo> path (GitHub Classroom org repos). roster.txt: one
# student per line, '#' comments OK.
#
# Env overrides: REPO_NAME (default ace-module2-lab), SA_EMAIL, POOL, PROVIDER.
set -euo pipefail

PROJECT="${1:-}"; shift || true
REPO_NAME="${REPO_NAME:-ace-module2-lab}"
POOL="${POOL:-github-actions}"
PROVIDER="${PROVIDER:-github-oidc}"
REMOVE=0
ROSTER_FILE=""
STUDENTS=()

if [[ -z "$PROJECT" ]]; then
  echo "usage: $0 <gcp-project-id> [-r] <student|owner/repo> ... | -f roster.txt" >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) ROSTER_FILE="${2:-}"; shift 2 ;;
    -r) REMOVE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) STUDENTS+=("$1"); shift ;;
  esac
done

if [[ -n "$ROSTER_FILE" ]]; then
  [[ -f "$ROSTER_FILE" ]] || { echo "error: roster file not found: $ROSTER_FILE" >&2; exit 2; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && STUDENTS+=("$line")
  done < "$ROSTER_FILE"
fi
[[ ${#STUDENTS[@]} -gt 0 ]] || { echo "error: no students given" >&2; exit 2; }

SA="${SA_EMAIL:-codemender-ci@${PROJECT}.iam.gserviceaccount.com}"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

# -- ensure the provider condition admits class repos (idempotent) -----------
# setup-wif.sh pins the provider to one repo for testing; a class needs the
# name-based coarse filter. The IAM bindings below stay the real gate.
WANT_CONDITION="assertion.repository.endsWith('/${REPO_NAME}')"
HAVE_CONDITION=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
  --format='value(attributeCondition)')
if [[ "$HAVE_CONDITION" != "$WANT_CONDITION" ]]; then
  echo ">> updating provider condition to: $WANT_CONDITION"
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
    --attribute-condition="$WANT_CONDITION"
else
  echo ">> provider condition already class-shaped"
fi

# -- roster bindings -----------------------------------------------------------
verb="add"; [[ "$REMOVE" -eq 1 ]] && verb="remove"
for S in "${STUDENTS[@]}"; do
  REPO="$S"
  [[ "$S" != */* ]] && REPO="${S}/${REPO_NAME}"
  MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"
  echo ">> ${verb}: $REPO"
  gcloud iam service-accounts "${verb}-iam-policy-binding" "$SA" \
    --project="$PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="$MEMBER" >/dev/null
done

echo
echo ">> current roster (repos allowed to impersonate $SA):"
gcloud iam service-accounts get-iam-policy "$SA" --project="$PROJECT" \
  --format=json | python3 -c '
import json,sys
p=json.load(sys.stdin)
for b in p.get("bindings",[]):
    if b["role"]=="roles/iam.workloadIdentityUser":
        for m in b["members"]:
            print("   ", m.rsplit("attribute.repository/",1)[-1] if "attribute.repository/" in m else m)
'

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
cat <<EOF

============================================================
Class handout — every student sets the SAME three repo
VARIABLES (Settings → Secrets and variables → Actions → Variables),
or runs:

  gh variable set GCP_WIF_PROVIDER  --repo <you>/${REPO_NAME} --body "${WIF_PROVIDER}"
  gh variable set GCP_SA_EMAIL      --repo <you>/${REPO_NAME} --body "${SA}"
  gh variable set GCP_QUOTA_PROJECT --repo <you>/${REPO_NAME} --body "${PROJECT}"

None of these values are secret. A repo not on the roster above
gets "unable to impersonate" at the auth step — add it with:
  $0 ${PROJECT} <github-username>
Revoke one student:
  $0 ${PROJECT} -r <github-username>
============================================================
EOF
