# Module 2 Lab — CodeMender CI/CD Guardrail

Build an **autonomous security guardrail** into a CI/CD pipeline. When code is
pushed, Google **CodeMender** (the `cm` CLI) scans it, blocks the deployment if
it finds a HIGH/CRITICAL vulnerability, publishes a machine-readable report, and
opens a pull request that **patches the bug automatically**.

Your target application is **OWASP Juice Shop** — a deliberately vulnerable
web app. CodeMender will surface several HIGH/CRITICAL bugs in `routes/` (SQL
injection, file-upload XXE / Zip-Slip, …) and auto-patch the most severe ones.

---

## What you'll learn

- How an AI security agent (CodeMender) is wired into GitHub Actions as a
  **deployment gate**.
- The real CodeMender pipeline: `find` (scan) → `report` → `fix` (auto-patch).
- Provisioning and using **CI secrets** safely.
- **Fail-safe gating**: turning a scan result into a red/green deploy decision.
- **Autonomous remediation**: an agent opening a PR with a code fix.

## How CodeMender actually works (read this first)

CodeMender is a **cloud service with a local executor**, not an on-device
scanner. The `cm` binary is a thin client: when you run `cm find`, it **uploads
your in-scope source** to `codemender.pa.googleapis.com`, where a server-side AI
agent reasons about vulnerabilities and drives the patch. Practically:

- **Your code leaves the machine.** Only point `cm` at code you're allowed to
  share. (Juice Shop is open source, so we're fine.)
- Findings + patches are stored locally in `~/.codemender/` and read back with
  `cm report`.
- The scan is scoped to **`routes/`** in this lab — small (well under cm's
  ~10 MB per-scan upload limit) and home to the login SQL injection.

---

## Prerequisites

This repository is your lab template. It already contains:

- `.github/workflows/codemender-pipeline.yml` — the guardrail workflow.
- `.github/scripts/cm_triage.py` — turns the JSON report into a gate decision.
- A private **Release** (`cm-cli-v0.1.0`) holding the `cm` binary, which the
  workflow downloads in CI.

> If you're an instructor setting this up for students, see
> [`INSTRUCTOR.md`](./INSTRUCTOR.md) first — there's per-repo setup
> (the `cm` release + a repo setting) that must be done before students start.

---

## Step 1 — Initialize the work environment

1. Open your copy of this repository on GitHub.
2. Confirm the workflow directory exists and contains the pipeline:

   ```
   .github/
     workflows/
       codemender-pipeline.yml
     scripts/
       cm_triage.py
   ```

   That's the GitHub Actions structure GitHub auto-discovers — any `*.yml` under
   `.github/workflows/` becomes a pipeline.

## Step 2 — Provision the secret

CodeMender will (in its GA API form) authenticate with a **single API key**.
Add it as a repository secret:

1. Go to **Settings → Secrets and variables → Actions**.
2. Click **New repository secret**.
3. Name: **`GOOGLE_API_KEY`**  — Value: your Google API key.
4. Save.

Then enable the pipeline's ability to open a remediation PR:

5. Go to **Settings → Actions → General → Workflow permissions**.
6. Select **Read and write permissions**, and check
   **Allow GitHub Actions to create and approve pull requests**. Save.

> **Note (honest detail):** the lab's `cm v0.1.0` binary authenticates with an
> embedded build key, so the pipeline will run even if `GOOGLE_API_KEY` isn't
> enforced yet. We wire the secret in now so the lab matches the GA model with
> **zero changes later** — and so you practice secret provisioning, a core
> DevSecOps skill.

## Step 3 — Understand the guardrail

Open `.github/workflows/codemender-pipeline.yml`. It runs on every push to
`main` (and on manual dispatch). The steps map directly onto real `cm` commands:

| Stage | Command | What it does |
|---|---|---|
| **Install** | `gh release download cm-cli-v0.1.0` | Pulls the `cm` binary (private Release asset) using the built-in `GITHUB_TOKEN` |
| **Init** | `cm init` | Mints the local CodeMender identity key |
| **Scan** | `cm find routes -y` | Uploads `routes/` and runs the server-side scan |
| **Report** | `cm report -f json` | Exports findings → uploaded as the **`codemender-report`** artifact |
| **Triage** | `cm_triage.py` | Counts HIGH/CRITICAL, ranks them, selects the top **N** (default 3) to fix |
| **Patch** | `cm fix <id>` (looped over top-N) | Generates + applies a security patch for each selected finding |
| **PR** | `peter-evans/create-pull-request` | Opens one remediation PR containing all the patches |
| **Gate** | (exit 1 if HIGH/CRITICAL) | Turns the run **red** and blocks deployment |

> **Why no `--fail-on=high,critical` flag?** The real `cm` has no such flag — a
> scan exits `0` whether or not it finds bugs. The **gate is something *you*
> build**: parse `cm report -f json` and fail the job on HIGH/CRITICAL. That's
> the `cm_triage.py` + "Security Gate" steps. This is the real, transferable
> pattern for wiring any scanner into a pipeline.

## Step 4 — Trigger and test the agent

Trigger a run any of these ways:

- **Manual — UI (easiest):** **Actions** tab → **CodeMender CI/CD Guardrail**
  in the left sidebar → **Run workflow** ▸ → choose `main` → **Run workflow**.
  This is the `workflow_dispatch` trigger — best for re-running on the *same*
  commit (e.g. the Part B exercise).
- **Manual — CLI:** with the [GitHub CLI](https://cli.github.com):
  ```bash
  gh workflow run codemender-pipeline.yml --repo <owner>/<repo> --ref main
  ```
- **Push:** commit anything to `main` — the `on: push` trigger fires automatically.

| Trigger | How | Opens a fix PR? |
|---|---|---|
| `workflow_dispatch` | Run workflow button / `gh workflow run` | ✅ yes |
| `push` to `main` | any commit to `main` | ✅ yes |

> The `pull_request` trigger is intentionally **not** enabled (it created
> branch-less red runs on the bot's own remediation PR and GitHub approval
> prompts). The workflow keeps the `github.event_name != 'pull_request'` guards,
> so you can re-add a `pull_request:` trigger to gate PRs if you want.

Then open the **Actions** tab and watch the run. Expect it to:

1. Install `cm` and initialize cleanly.
2. Scan `routes/` and surface multiple **HIGH/CRITICAL** findings (e.g. SQL
   injection in `routes/login.ts` / `routes/search.ts`, file-upload XXE /
   Zip-Slip in `routes/fileUpload.ts`).
3. Upload the `codemender-report` artifact.
4. Open a PR titled **"CodeMender: autonomous security remediation"** with
   patches for the top-N findings.
5. **Fail red** at the Security Gate (correct — `main` stays blocked until the
   findings are resolved).

---

## ✅ Success criteria (what you must demonstrate)

| # | Criterion | Where the evidence is |
|---|---|---|
| 1 | **Workflow executes** — clean `cm` install + init | Actions run log: "Install CodeMender CLI" + "Initialize CodeMender Workspace" steps green |
| 2 | **Pipeline gating (fail-safe)** — a HIGH/CRITICAL bug turns the run red and blocks deploy | Run is **red**; "Security Gate" step shows `error::Deployment blocked` |
| 3 | **Artifact generation** — `codemender-report` with `cm-security-report.json` | Run **Summary** → Artifacts → `codemender-report` (downloadable) |
| 4 | **Autonomous remediation** — agent-opened branch/PR with the fix | **Pull requests** tab: PR from `codemender/auto-remediation` with structural patch(es) to `routes/` (e.g. a SQL injection rewritten as a parameterized query) |

The job **Summary** also shows a "CodeMender Triage" table (severity counts +
the finding selected for remediation) — a quick at-a-glance for grading.

---

## Part B (exploration) — observe the non-determinism

CodeMender runs **server-side**, so the scan is *probabilistic*: the exact set
of findings and which one ranks #1 can shift between runs. Make that visible:

1. Trigger the pipeline **3 times** (Actions → **Run workflow**, or push small commits).
2. From each run's **Summary**, download the **`codemender-report`** artifact.
3. Compare them — note how the finding count, severities, and the remediated
   set vary run-to-run, and how each run's remediation PR differs.

**Reflect:** why does an AI security agent return different results on identical
code? What does that imply for using one as a *blocking* deployment gate?
> Hint: the gate keys off **severity counts**, not a specific finding — so it
> stays reliable as a fail-safe even as individual findings shift. The lab fixes
> the **top N** (default 3) findings per run so coverage doesn't hinge on which
> single bug happened to rank first.

## Troubleshooting

- **"GitHub Actions is not permitted to create or approve pull requests"** →
  you missed Step 2.5/2.6 (the workflow-permissions toggle).
- **`gh release download` fails / `cm-linux` not found** → the `cm` release
  isn't published on *your* repo. Ask your instructor (see `INSTRUCTOR.md`).
- **Run is green with 0 findings** → the scan didn't surface a HIGH/CRITICAL.
  Confirm `SCAN_PATH` is `routes` and that `routes/login.ts` still contains the
  string-built SQL query. (CodeMender runs server-side, so exact findings can
  vary run-to-run.)
- **`RESOURCE_EXHAUSTED` / quota errors** → in this lab everyone shares the
  binary's embedded key; stagger your runs or retry. (The GA per-user
  `GOOGLE_API_KEY` removes this.)
- **Scan takes a while** → `cm find` runs a multi-round server-side agent;
  several minutes is normal. The job timeout is 45 minutes.

## Caveats to understand

- `cm find` **uploads source** to Google. Fine for Juice Shop; never point it at
  code you can't share.
- During a scan/fix, the server-side agent can run shell commands **on the
  runner** (inside a path sandbox). That's expected CodeMender behavior.
- This lab scans only `routes/`. Scanning the whole repo would exceed cm's
  ~10 MB upload limit and need chunking — out of scope here.
