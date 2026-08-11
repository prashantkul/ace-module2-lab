# Porting This Lab to Qwiklabs / Google Cloud Skills Boost

What a Qwiklabs lab author needs to replicate the CodeMender CI/CD Guardrail
lab. Read [`DESIGN.md`](./DESIGN.md) first for the auth architecture — this
doc only covers what changes in the Qwiklabs environment.

**TL;DR:** the workflow file is the visible half of the lab. Copying the repo
gives you the pipeline, scripts, and docs — but auth lives in GCP-side
infrastructure your lab provisioning must create. The good news: the Qwiklabs
model (one ephemeral project per student, broad permissions) fits this design
*better* than a shared classroom project, and deletes most of the instructor
machinery.

---

## 1. What transfers as-is

- The template repo: workflow, `cm_triage.py` / `extract_cm_diff.py`,
  `setup-wif.sh`, student README, grading rubric (INSTRUCTOR.md §3).
- The keyless (WIF) auth design — **no secrets exist anywhere**, so nothing
  in the lab collides with Qwiklabs credential policies, and lab teardown
  needs zero credential cleanup (deleting the project deletes the pool, SA,
  and bindings).

## 2. What changes: per-student projects replace the class roster

In the classroom rollout, one shared project + a roster of per-repo IAM
bindings serves everyone. In Qwiklabs, **each student's ephemeral project
trusts exactly one repo — their own**. Consequences:

- No roster (`wif-add-students.sh` class mode is unused).
- No shared quota: each student's scans bill and throttle their own project.
  (This is the "per-student projects" variant deferred in DESIGN.md §Future
  work — Qwiklabs provisioning *is* the missing provisioner.)
- Students have broad permissions on their project, so **the student can
  create the WIF trust themselves as a lab task** — pedagogically better
  than receiving it pre-made.

## 3. Lab startup script (runs at provision time)

```bash
# Qwiklabs project startup — Terraform or startup script equivalent
PROJECT=$(gcloud config get-value project)
gcloud services enable aiplatform.googleapis.com \
                       iamcredentials.googleapis.com \
                       sts.googleapis.com --project=$PROJECT

gcloud iam service-accounts create codemender-ci \
  --project=$PROJECT --display-name="CodeMender CI"

SA=codemender-ci@$PROJECT.iam.gserviceaccount.com
# BOTH roles required — aiplatform.user does NOT include serviceusage.services.use
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$SA" --role="roles/aiplatform.user"
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$SA" --role="roles/serviceusage.serviceUsageConsumer"
```

The student's Qwiklabs identity needs (beyond the usual editor grant):
`roles/iam.workloadIdentityPoolAdmin` and `roles/iam.serviceAccountAdmin`
on the project, so they can run `setup-wif.sh` in Step 2 below.

## 4. Student instructions (replaces README Step 2)

1. **Create your repo** from the template (their own GitHub account).
2. **Create the trust chain** — in Cloud Shell:

   ```bash
   git clone https://github.com/<you>/ace-module2-lab && cd ace-module2-lab
   ./lab/setup-wif.sh $GOOGLE_CLOUD_PROJECT <you>/ace-module2-lab
   ```

   The script prints their three repo-variable values.
3. **Set the three repo variables** (`GCP_WIF_PROVIDER`, `GCP_SA_EMAIL`,
   `GCP_QUOTA_PROJECT`) — plain variables, not secrets.
4. **Workflow permissions:** Settings → Actions → General → "Read and write
   permissions" + "Allow GitHub Actions to create and approve pull requests".
5. Push to `main` (or dispatch) and watch the guardrail run.

## 5. The `cm` binary: vendor it

The workflow downloads `cm` from a Release on the student's own repo, and
**GitHub does not copy Releases on template/fork**. In the classroom rollout
the instructor publishes it per repo; in Qwiklabs that's dead weight. For the
Qwiklabs template, **commit `cm-linux` into the repo** (~29 MB) and replace
the "Install CodeMender CLI" download step with a `chmod +x`. One less
moving part, no `gh` auth needed in Cloud Shell, and timed labs care about
friction more than repo size. (Public binary download URL: INSTRUCTOR.md §1.)

## 6. Verify before shipping: the one real risk

Everything above is mechanical except this: **confirm the CodeMender backend
accepts calls billed to a Qwiklabs-provisioned project** (service
availability + Vertex AI quota in the lab project template). That's exactly
what `.github/workflows/wif-auth-test.yml` is for — from a trial Qwiklabs
project, run steps 1–4 above against a test repo, then dispatch the WIF
auth test. Green in ~5 minutes = the port is viable. Also size Vertex AI
quota in the project template for ~2 full scans + 3 fix sessions per student
(a re-run headroom above the single graded run).

## 7. Grading / activity tracking

Qwiklabs' checker sees only GCP-side state. Checkable there: the SA exists
with both roles; the pool/provider exist; the SA has a `workloadIdentityUser`
binding (proves Step 2); Vertex AI request metrics > 0 (proves a scan ran).
The GitHub-side outcomes (red gate, report artifact, remediation PR) are
invisible to the checker — grade those via the rubric in INSTRUCTOR.md §3
(student submits their repo URL) or accept the GCP-side signals as proxy.

## 8. Teardown

Nothing. Project deletion removes the SA, pool, provider, and bindings; no
credential outlives the lab. The student's repo keeps working-looking config
(three variables) that points at a dead project — harmless by design, since
none of it was secret.
