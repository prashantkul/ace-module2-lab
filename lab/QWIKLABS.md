# Qwiklabs Write-Up: CodeMender CI/CD Guardrail

Ready-to-use lab content for Qwiklabs / Skills Boost. Students set up a
GitHub repo, run the guardrail workflow, and verify four outcomes. Repos are
**public** — safe here because this lab contains no secrets anywhere (auth
is keyless Workload Identity Federation; see [`DESIGN.md`](./DESIGN.md)),
and it makes verification a matter of opening URLs.

**Before publishing, the course team fills in:** the three variable values
(printed by `wif-class-access.sh open`). There is no student roster —
admission is by the **fixed repo name** `ace-module2-lab`, and the course
team opens access before the session and closes it after. The shared,
allow-listed GCP project already exists — Qwiklabs provisions nothing.

---

## Lab instructions (student-facing)

### Setup — about 5 minutes

1. **Create your repo.** Open the course template on GitHub → **Use this
   template → Create a new repository**. Name it **exactly** `ace-module2-lab`
   (Google Cloud admits your pipeline by that name — any other name fails
   auth), owner = your account, visibility = **Public**.

2. **Add the three variables.** In your repo: **Settings → Secrets and
   variables → Actions → Variables tab → New repository variable.** Add
   these exactly (they are the same for everyone and not secret):

   | Name | Value |
   |---|---|
   | `GCP_WIF_PROVIDER` | *(value from lab page)* |
   | `GCP_SA_EMAIL` | *(value from lab page)* |
   | `GCP_QUOTA_PROJECT` | *(value from lab page)* |

3. **Allow the pipeline to open pull requests.** **Settings → Actions →
   General → Workflow permissions:** select **Read and write permissions**
   and check **Allow GitHub Actions to create and approve pull requests**.
   Save.

### Run — about 20 minutes, mostly waiting

4. Open the **Actions** tab → **CodeMender CI/CD Guardrail** → **Run
   workflow**. Watch it scan your code, generate a report, auto-patch the
   top findings, and open a pull request.

5. **The run ends with a red ❌ — that is success.** The Security Gate found
   HIGH/CRITICAL vulnerabilities and blocked "deployment." A green run would
   mean the guardrail failed to guard.

### Verify — four checks, all in the browser

| # | Check | Where |
|---|---|---|
| 1 | Scan ran clean | The run's steps "CodeMender Scan" and "Triage Findings" are green ✅ |
| 2 | Gate blocked deployment | The step "Security Gate (fail on HIGH/CRITICAL)" is red ❌ with *"Deployment blocked"* |
| 3 | Report was produced | The run's **Summary** page lists artifact **`codemender-report`** |
| 4 | Auto-remediation PR exists | **Pull requests** tab shows **"🤖 CodeMender: autonomous security remediation"** — open it and look at the patches |

If something fails instead:

- **Run stops at "Check WIF configuration"** → a variable is missing or
  misspelled (step 2 — Variables tab, not Secrets).
- **Auth step fails with "unable to impersonate"** → your repo isn't named
  exactly `ace-module2-lab`, or class access isn't open — contact the course
  team.
- **"not permitted to create or approve pull requests"** → step 3 was
  missed.

---

## Grader verification (no access needed — repos are public)

Browser: open `github.com/<student>/ace-module2-lab` → **Actions** (red
guardrail run), the run's **Summary** (artifact), **Pull requests** (bot
PR). Thirty seconds per student.

Or from a terminal, with any authenticated `gh`:

```bash
R=<student>/ace-module2-lab

# 1+2 — latest guardrail run exists and ended red (gate)
gh run list -R $R --workflow codemender-pipeline.yml -L 1

# 3 — report artifact present on that run
gh api repos/$R/actions/runs/$(gh run list -R $R -L 1 --json databaseId --jq '.[0].databaseId')/artifacts --jq '.artifacts[].name'

# 4 — remediation PR opened by the bot
gh pr list -R $R --head codemender/auto-remediation
```

Expected: run conclusion `failure` (the red gate), artifact
`codemender-report`, and one open PR titled "🤖 CodeMender: autonomous
security remediation".

---

## Course-team notes

- **Access switch:** `./lab/wif-class-access.sh <shared-project> open`
  before the session, `close` after. While open, any repo named
  `ace-module2-lab` is admitted — that's the deliberate trade for zero
  per-student ops, so don't leave it open between cohorts.
- **Template:** commit the `cm-linux` binary into the Qwiklabs template (and
  swap the release-download step for `chmod +x`) — GitHub doesn't copy
  Releases to student copies, and this removes the most confusing failure
  mode. Binary URL: INSTRUCTOR.md §1.
- **Quota:** all usage bills to the shared allow-listed project. Budget ~2
  scans + 3 fix sessions per student; if a cohort throttles
  (`RESOURCE_EXHAUSTED`), add another allow-listed project per section —
  allow-listing has lead time.
- **Teardown:** `wif-class-access.sh close` — one command. Student repos
  keep three harmless public variables.
