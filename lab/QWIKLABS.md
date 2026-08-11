# Bringing This Lab to Qwiklabs / Google Cloud Skills Boost

This guide is for a lab author who wants to run the CodeMender CI/CD
Guardrail lab on Qwiklabs. It walks through what you get for free, what you
need to build, and the one thing you should verify before committing to the
port. For the full story on how the authentication works, read
[`DESIGN.md`](./DESIGN.md) — here we'll only cover what's different in a
Qwiklabs environment.

Here's the short version: **copying the repository gives you half the lab.**
The workflow, the scripts, and the student guide all transfer unchanged. But
the pipeline authenticates to Google Cloud through infrastructure that lives
*outside* the repo — a service account, a workload identity pool, and a trust
relationship with the student's GitHub repository. Someone has to create
those, and in Qwiklabs that "someone" is your lab provisioning plus one
command the student runs.

The genuinely good news: Qwiklabs is a *better* home for this design than a
traditional classroom. You'll see why in a moment.

---

## Why Qwiklabs makes this easier, not harder

In the classroom version of this lab, every student shares one Google Cloud
project. That forces some machinery: the instructor keeps a roster of student
repositories, admits each one with an IAM binding, hands out quota from a
shared pool, and revokes people who misbehave.

Qwiklabs turns all of that off. Each student gets their own throwaway
project, so:

- **There is no roster.** Each project trusts exactly one GitHub repo — the
  student's own. Nothing to admit anyone to, nothing to revoke.
- **There is no shared quota.** If a student re-runs their scan five times,
  they throttle only themselves.
- **The student builds the trust chain with their own hands.** Qwiklabs
  students have broad permissions on their project, so creating the identity
  federation becomes a lab step rather than something an instructor did for
  them — which is honestly the better lesson. This lab is about CI/CD
  security; letting students construct "my pipeline can prove to Google which
  repo it is" is on-topic in the best way.

And because the design contains **no secrets and no keys at all**, there is
nothing here that collides with Qwiklabs credential policies, and nothing to
clean up when the lab ends. When the project is deleted, everything auth-
related dies with it.

## What your lab startup script needs to do

Before the student arrives, the project needs three things: the right APIs
enabled, a service account for the pipeline to act as, and that service
account's two roles. This is about ten lines of provisioning:

```bash
PROJECT=$(gcloud config get-value project)

gcloud services enable aiplatform.googleapis.com \
                       iamcredentials.googleapis.com \
                       sts.googleapis.com --project=$PROJECT

gcloud iam service-accounts create codemender-ci \
  --project=$PROJECT --display-name="CodeMender CI"

SA=codemender-ci@$PROJECT.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$SA" --role="roles/aiplatform.user"
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$SA" --role="roles/serviceusage.serviceUsageConsumer"
```

Two details worth calling out:

- **Both roles really are required.** `aiplatform.user` looks sufficient but
  doesn't include `serviceusage.services.use`, and without the second role
  the pipeline fails mid-scan with a confusing quota error. This is the most
  common way to break the lab while "simplifying" it.
- **The student's Qwiklabs identity needs two extra roles** on top of your
  usual grant: `roles/iam.workloadIdentityPoolAdmin` and
  `roles/iam.serviceAccountAdmin`. Those are what let the student run the
  trust-setup script in the next section.

## What the student does

This replaces Step 2 of the student README. Five steps, all of them quick:

1. **Create a repo from the template** under their own GitHub account.

2. **Build the trust chain.** In Cloud Shell:

   ```bash
   git clone https://github.com/<you>/ace-module2-lab && cd ace-module2-lab
   ./lab/setup-wif.sh $GOOGLE_CLOUD_PROJECT <you>/ace-module2-lab
   ```

   This creates the workload identity pool and provider in their project and
   tells Google "workflows from this one GitHub repo may act as the CI
   service account." When it finishes, it prints three values.

3. **Paste those three values into the repo** as Actions *variables* (not
   secrets — that's the point of the design): `GCP_WIF_PROVIDER`,
   `GCP_SA_EMAIL`, and `GCP_QUOTA_PROJECT`.

4. **Let the pipeline open pull requests.** In the repo: Settings → Actions →
   General → Workflow permissions → choose "Read and write permissions" and
   check "Allow GitHub Actions to create and approve pull requests."

5. **Push to `main`** (or trigger the workflow manually) and watch the
   guardrail do its thing: scan, report, auto-fix, remediation PR, and a
   deliberately red security gate.

## One change we recommend: commit the `cm` binary

The workflow currently downloads the `cm` CLI from a GitHub Release on the
student's own repository — and GitHub does **not** copy Releases when a repo
is created from a template. In the classroom version, the instructor
publishes that release onto each student repo. In Qwiklabs there's no
instructor in the loop, and asking students to authenticate `gh` and publish
a release is friction a timed lab doesn't need.

So for the Qwiklabs template: **commit the `cm-linux` binary into the repo**
(about 29 MB) and replace the workflow's download step with a `chmod +x`.
It's a less elegant repo, but it removes an entire category of student
confusion, and timed labs should always trade elegance for fewer moving
parts. The public download URL for the binary is in INSTRUCTOR.md §1.

## Before you build anything: verify the one real unknown

Everything above is mechanical. The one question that isn't: **does the
CodeMender backend accept requests billed to a Qwiklabs-provisioned
project?** Service availability and Vertex AI quota in your project template
are outside anyone's workflow file, and no amount of correct YAML fixes a
backend that says no.

Happily, this repo ships the exact test you need. From a trial Qwiklabs
project, walk through the student steps above with a test repo, then trigger
the **"WIF Auth Test (CodeMender)"** workflow from the Actions tab. It
authenticates keylessly and runs a real one-file scan against the live
backend. Green in about five minutes means the port is viable; if it fails,
the step it fails on tells you whether the problem is the token exchange,
the roles, or the backend.

While you're at it, size the Vertex AI quota in your project template for
roughly **two full scans plus three fix sessions per student** — one graded
run plus headroom for the inevitable re-run.

## Grading

Qwiklabs' activity tracker can only see the Google Cloud side of the lab.
That still gives you useful signals: the service account exists with both
roles, the pool and provider exist, the service account has a
`workloadIdentityUser` binding (which proves the student completed the trust
setup), and Vertex AI request metrics above zero (which proves a scan
actually ran).

What the tracker *can't* see are the GitHub-side outcomes — the red security
gate, the report artifact, the remediation PR. Those are the four rubric
criteria in INSTRUCTOR.md §3, so either have students submit their repo URL
for review, or accept the GCP-side signals as a reasonable proxy and let the
rubric be a self-check.

## Teardown

There isn't any. Deleting the project — which Qwiklabs does automatically —
removes the service account, the pool, the provider, and the trust bindings.
No credential outlives the lab, because no credential ever existed. The
student's repo keeps three now-orphaned variables pointing at a dead
project, which is harmless by design: none of them were ever secret.
