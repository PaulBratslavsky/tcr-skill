---
name: tcr-kentbeck
description: >
  Enforces Test && Commit || Revert (TCR): run tests after each micro-change,
  commit only on green, discard the change on red.
  ALWAYS trigger when the user mentions TCR, test-commit-revert, or wants strict incremental commits with no red
  states kept in the working tree or history.
  The agent makes tiny changes, runs the full test suite through the bundled tcr.sh helper, and either commits on
  green or fully reverts on red, never accumulating broken code, and logs every red to tcr-failure-log.md.
  Do NOT trigger for general TDD questions, test framework setup, CI pipelines,
  or code coverage. Those do not need this skill.
license: MIT
compatibility: Requires git and bash (the bundled tcr.sh helper has no other dependencies)
---

# TCR (Test && Commit || Revert)

## Use the helper: `tcr.sh`

This skill ships a helper script, **`tcr.sh`**, in the same directory as this `SKILL.md`. **Run every TCR step through it.** Don't decide commit/revert by hand. The script runs the full suite and then does exactly one thing:

| Tests | What `tcr.sh` does | Exit code |
|-------|--------------------|-----------|
| pass | `git add -A` and commit with your message | `0` |
| fail | **full revert** to `HEAD` (tracked, staged **and new untracked files**), keeping the failure log, then appends a log entry and commits the log | `1` |
| none collected | nothing (no commit, no revert); see [Empty test suite](#empty-test-suite-new-projects) | `3` |
| setup problem | nothing (not a git repo, no commits yet, unknown test command) | `2` |

```bash
# from anywhere inside the repo; <skill-dir> is the directory containing this SKILL.md
bash <skill-dir>/tcr.sh -m "Return Fizz for multiples of three"

# explicit test command (otherwise auto-detected, or taken from $TCR_TEST_CMD)
bash <skill-dir>/tcr.sh -m "Validate email on POST /users" -- npm test
```

`-m` is the commit message on green and the **attempted change** recorded in the log on red, so always pass a short imperative description of the step.

Other options: `-l FILE` (log path, default `tcr-failure-log.md` at the repo root), `--allow-empty-suite`, `--no-log-commit` (leave the log entry uncommitted; it is still preserved by later reverts), `-h`.

If the helper can't be used (e.g. no bash), follow the same rules manually with the commands in [Git behavior](#git-behavior).

## Non-negotiables

When this skill applies, treat TCR as **mandatory**, not optional:

1. **One small step.** Make the smallest change that moves the code forward *and keeps every test passing*. In TCR a failing test is red, and red is always reverted, so **you cannot commit a failing test on its own.** Write the new test **together with the minimal implementation that makes it pass**, and run them as one step. (If you want an explicit "see it fail first" phase, use the `tcr` skill with git-gamble's `--red`.) To check that a new test really tests something, you may run it once *outside* the TCR cycle before adding the implementation, but never commit that state.
2. **Run tests.** Use the project's real test command (see [Detecting the test command](#detecting-the-test-command)). **Always run the full suite**: e.g. `pytest` with no path arguments, `npm test` / `pnpm test` / `yarn test`, `cargo test`, `go test ./...`, `make test` if that runs everything. Do **not** narrow to a single file, class, or `-k` filter unless the user explicitly asks for a scoped run. `tcr.sh` runs the command you give it, so give it the full one.
3. **Green → commit.** If tests pass, commit that step immediately with a message that describes *what* changed (present tense, imperative). `tcr.sh` does this.
4. **Red → full revert.** If tests fail, **do not** keep any part of the change. Restore the working tree **and index** to the last commit **and delete new untracked files** the step created. Then retry with a smaller or different step. `tcr.sh` does this. A partial revert such as `git restore .` alone is not enough: it leaves new files and staged edits behind, so the tree is still red.
5. **Red → log.** Every revert is recorded in **`tcr-failure-log.md`** at the repository root: **when** (UTC timestamp), the **attempted change** (`-m`), the **test command and exit code**, the **discarded changes** (diffstat and new files), and the **tail of the test output**. `tcr.sh` writes the entry and **commits the log right away**, so a later revert can never erase it. The file is append-only; never delete past entries. After a red, read the entry, optionally fill in "Next", and try a smaller step.

Do **not** accumulate uncommitted red edits "to fix in the next message." Red means revert first, then log.

## Workflow loop

```
edit (tiny: test + minimal code) → tcr.sh -m "what this step does"
        ├─ exit 0 (green) → committed → next tiny step
        ├─ exit 1 (red)   → reverted + logged → read tcr-failure-log.md → smaller step
        └─ exit 3 (empty) → add a test with its implementation (or scaffold with --allow-empty-suite)
```

Start each step from a **clean working tree** (`git status` shows nothing). `tcr.sh` commits *everything* on green and discards *everything* (except the failure log) on red, including unrelated edits and untracked files that are not git-ignored.

## Empty test suite (new projects)

A brand-new project often has no tests yet, and some runners treat that as a failure (pytest exits `5`; Jest/Vitest print "No tests found"). That is **not** a red: nothing is broken, there is just nothing to check. `tcr.sh` reports it with exit code `3` and changes nothing.

- Preferred: make the first TCR step **one test plus its minimal implementation**, so the suite is never empty when it matters.
- Scaffolding (config files, empty package layout) that you want committed before any test exists: run `tcr.sh --allow-empty-suite -m "Scaffold project"` (or make that first commit by hand). `tcr.sh` needs at least one commit to revert to.

## Git behavior

- **Commit**: Keep commits small and atomic: one green step per commit. `tcr.sh` stages everything (`git add -A`), which is why each step must start from a clean tree.
- **Full revert on red** (what `tcr.sh` runs; use the same if doing it by hand):

  ```bash
  cp tcr-failure-log.md /tmp/tcr-log.bak 2>/dev/null   # keep the log
  git reset --hard HEAD                                # tracked + staged changes
  git clean -fd -e /tcr-failure-log.md                 # new untracked files (ignored files are kept)
  cp /tmp/tcr-log.bak tcr-failure-log.md 2>/dev/null   # restore any uncommitted log entries
  # append the entry, then: git add tcr-failure-log.md && git commit -m "tcr: log failure: …"
  ```

  This only discards **uncommitted** work. Commit history is never rewritten.
- **Never commit a red state.** If a commit was made by mistake while red, use the project's agreed recovery (e.g. `git reset --soft HEAD~1` only when the user expects history rewriting).
- **Branch**: Same rules on feature branches: never push a sequence that leaves mainline patterns broken if your workflow requires linear green history.

## Detecting the test command

`tcr.sh` resolves the command in this order: arguments after `--`, then `$TCR_TEST_CMD`, then auto-detection:

1. `package.json` with a `test` script → `pnpm test` / `yarn test` (by lockfile) or `npm test`.
2. `Makefile` with a `test:` target → `make test`.
3. `Cargo.toml` → `cargo test`; `go.mod` → `go test ./...`.
4. pytest config (`pytest.ini`, `conftest.py`, `tox.ini`, `[tool.pytest…]` in `pyproject.toml`, `[tool:pytest]` in `setup.cfg`) or tracked `test_*.py` / `*_test.py` files → `pytest` (or `python3 -m pytest`).
5. `pom.xml` → `mvn -q test`; executable `gradlew` → `./gradlew test`.

If the project documents a different "full" command (README, CI config such as `.github/workflows`, or `make test-all`), pass that one explicitly after `--`. If it's still unclear, ask once. Do not invent a second test runner without reason.

## Agent conduct

- **Proactive**: After substantive edits, run the **full** test suite (through `tcr.sh`) before suggesting the task is done.
- **Honest**: If tests cannot be run in the environment, say so and either request permission to run them or describe exact commands for the user. Do not claim TCR compliance without a green run. Never weaken, skip, or delete tests or assertions to get green.
- **Read the log**: After a red, read the new entry in `tcr-failure-log.md` before the next attempt, and make the next step smaller.
- **Scope**: TCR applies to coding tasks that touch behavior covered by tests; pure docs-only changes may skip tests only when they cannot affect execution.

## Optional: user escape hatch

If the user explicitly says to **skip TCR** or **bend** the workflow for a one-off (e.g. WIP checkpoint), follow their instruction for that turn only, then return to TCR unless they say otherwise.
