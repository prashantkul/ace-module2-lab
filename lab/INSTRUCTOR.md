# Instructor Guide — CodeMender CI/CD Guardrail (Module 2)

Everything you need to deploy this lab to students and grade it. Student-facing
instructions are in [`README.md`](./README.md).

---

## 0. What's in the repo

| Path | Purpose |
|---|---|
| `.github/workflows/codemender-pipeline.yml` | The guardrail pipeline (provided, working) |
| `.github/scripts/cm_triage.py` | Parses `cm report -f json` → severity counts + gate decision + the top-N findings to auto-fix (`CM_FIX_LIMIT`, default 3) |
| `.github/scripts/extract_cm_diff.py` | Extracts cm's printed unified diff so CI can `git apply` it (cm doesn't always write the patch itself in a non-interactive shell) |
| `lab/README.md` | Student lab guide |
| `lab/INSTRUCTOR.md` | This file |
| `lab/publish-cm-release.sh` | Helper: publish the `cm` binary as a Release asset on a repo |
| Release `cm-cli-v0.1.0` | Holds `cm-linux` (runner) + `cm-mac` (local), downloaded in CI |

The target app is **OWASP Juice Shop**, imported as a single clean commit. The
16 upstream Juice Shop workflows were removed so the Actions tab shows **only**
the CodeMender guardrail.

---

## 1. The one non-obvious dependency: distributing `cm`

The workflow installs `cm` with:

```bash
gh release download cm-cli-v0.1.0 --repo "$GITHUB_REPOSITORY" --pattern cm-linux
```

The built-in `GITHUB_TOKEN` can only read releases **on the same repo**. So
**every student repo needs its own `cm-cli-v0.1.0` release** holding the
`cm-linux` asset. GitHub does **not** copy releases when a repo is forked or
created from a template — you must publish it per repo.

Use the helper (run it once per student repo, pointing at your local `cm`
binary):

```bash
# From a machine that has the cm binary:
./lab/publish-cm-release.sh <owner>/<repo> /path/to/cm-linux
```

**Distribution options:**

| Approach | How | Trade-off |
|---|---|---|
| **Per-repo release** (default) | Run `publish-cm-release.sh` against each student repo | One-time loop; keeps the single-secret model |
| **Central release + PAT** | Host `cm` on one repo; students add a read-only PAT secret and the workflow downloads cross-repo | Avoids per-repo publish, but adds a second secret |
| **Vendored binary** | Commit `cm-linux` into each repo and skip the download step | Simplest CI, but bloats the repo with a 29 MB binary |

For a class via **GitHub Classroom**, accept the assignment to generate the
student repos, then loop `publish-cm-release.sh` over them.

---

## 2. Per-repo setup checklist

For **each** repo students will use (or the template before distribution):

- [ ] Publish the `cm` release: `./lab/publish-cm-release.sh <owner>/<repo> <cm-linux>`
- [ ] **Settings → Actions → General → Workflow permissions:**
      "Read and write permissions" **and**
      "Allow GitHub Actions to create and approve pull requests" — both ON.
      (Required for the autonomous PR; without it `create-pull-request` errors.)
- [ ] Students add the **`GOOGLE_API_KEY`** secret (they do this themselves).
- [ ] (Optional) Branch protection on `main` so the red gate actually blocks
      merges — makes the "deployment blocked" outcome tangible.

> **Heads-up on shared quota:** until the GA per-user API key is enforced, all
> runs authenticate with the binary's embedded key and share server-side quota.
> For a large cohort, expect occasional `RESOURCE_EXHAUSTED`; have students
> stagger runs or retry.

---

## 3. Grading rubric

One push to `main` should produce all four artifacts. Map each criterion to
concrete, checkable evidence:

| # | Criterion | Pass evidence | Points |
|---|---|---|---|
| 1 | **Workflow execution** | Actions run exists; "Install CodeMender CLI" + "Initialize CodeMender Workspace" + "CodeMender Scan" steps are green (clean install & auth) | 25 |
| 2 | **Pipeline gating (fail-safe)** | The run is **red** because of the **"Security Gate"** step (`::error ::Deployment blocked … HIGH/CRITICAL`). A *red from an earlier crash* does **not** count | 25 |
| 3 | **Artifact generation** | Run **Summary → Artifacts** has **`codemender-report`** containing `cm-security-report.json`, and it's non-empty JSON | 25 |
| 4 | **Autonomous remediation** | A PR from branch **`codemender/auto-remediation`**, authored by the Actions bot, whose diff applies structural security fix(es) to `routes/` — e.g. a SQL injection rewritten as a parameterized query, or file-upload XXE/Zip-Slip hardened. Grade on *substance*, not a specific file (the scan is non-deterministic; the PR carries the top-N fixes). | 25 |

**Fast grading path:** open the run's **Summary** page — the "CodeMender Triage"
table shows severity counts and the remediated finding, and the Artifacts
section shows the report. Then open the **Pull requests** tab for criterion 4.

### Verify it via CLI (optional, for a TA)

```bash
R=<owner>/<repo>

# 1 & 2: latest run conclusion + that the Gate step failed
gh run list --repo "$R" --workflow "codemender-pipeline.yml" -L 1 \
  --json databaseId,conclusion,headBranch
RID=$(gh run list --repo "$R" -L 1 --json databaseId --jq '.[0].databaseId')

# 3: artifact present
gh api "repos/$R/actions/runs/$RID/artifacts" --jq '.artifacts[].name'   # → codemender-report

# 4: remediation PR present
gh pr list --repo "$R" --head codemender/auto-remediation \
  --json number,title,author,files --jq '.[] | {number,title,author:.author.login}'
```

---

## 4. Expected findings (so you know what "correct" looks like)

Scanning `routes/` reliably yields **~9–11 HIGH/CRITICAL** findings. The exact
set + ranking vary (server-side, non-deterministic); the pipeline auto-fixes the
top **N** (default 3, set by `CM_FIX_LIMIT`). The common ones:

- **SQL injection** in `routes/login.ts` / `routes/search.ts` — a string-built
  `sequelize.query(...)`. Correct fix = a **parameterized query** with bind
  `replacements`. Real `cm fix` output observed on `search.ts`:

  ```diff
  - models.sequelize.query(`SELECT * FROM Products WHERE ((name LIKE '%${criteria}%' OR description LIKE '%${criteria}%') ...)`)
  + models.sequelize.query('SELECT * FROM Products WHERE ((name LIKE :criteria OR description LIKE :criteria) ...)', { replacements: { criteria: `%${criteria}%` } })
  ```
- **File-upload** XXE / Zip-Slip / YAML-DOS in `routes/fileUpload.ts` — fix adds
  DOCTYPE/ENTITY rejection, a `startsWith(destDir)` path-traversal guard, and
  `yaml.safeLoad`.

Grade on **substance** (the vulnerability class is actually neutralized), not on
an exact file or diff — runs differ. `CM_FIX_LIMIT` in the workflow controls how
many findings each run remediates (1 = minimal single-fix lab).

---

## 5. Resetting between attempts

- Delete the remediation branch/PR: `gh pr close --delete-branch` or
  `git push origin --delete codemender/auto-remediation`.
- Re-running is idempotent: `create-pull-request` updates the existing PR rather
  than opening duplicates.

## 6. Cost / safety notes

- `cm find`/`cm fix` **upload source** to Google and let a server-side agent run
  sandboxed shell commands on the runner. Fine for Juice Shop (open source);
  communicate this to students as a real property of cloud AI security tools.
- GitHub-hosted runner minutes: a full run is typically several minutes
  (dominated by the server-side scan). Budget accordingly for large cohorts.
