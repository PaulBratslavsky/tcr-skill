# TCR Agent Skills

A collection of [Agent Skills](https://agentskills.io/specification) for **TCR (Test && Commit || Revert)** workflows.

---

## Skills

### `tcr` — TCR/TCRDD with git-gamble

Coaches users through **TCRDD** (TCR + TDD) using [`git-gamble`](https://git-gamble.is-cool.dev/).

- Explains the three phases (Red / Green / Refactor) and their `git gamble` flags
- Enforces strict TCR discipline: `git gamble` is the test run — no pre-running tests
- Coaches on surprise results and common mistakes

**Requirements:** `git`, [`git-gamble`](https://git-gamble.is-cool.dev/)

### `tcr-kentbeck` — Kent Beck's TCR

A faithful adaptation of [Kent Beck's own TCR skill](https://github.com/KentBeck/TCRSkill/), originally written for Cursor, made agent-agnostic per the [Agent Skills specification](https://agentskills.io/specification).

The agent makes tiny changes, runs the full test suite, commits on green, reverts on red — and logs every failure to `tcr-failure-log.md`. No tool dependencies beyond `git` and `bash`; the bundled `tcr.sh` helper detects and uses the project's existing test command (or takes one as an argument).

**Requirements:** `git`, `bash`

**Inspired by:** [KentBeck/TCRSkill](https://github.com/KentBeck/TCRSkill/)

---

## Installation

```bash
# Install tcr-kentbeck (from this fork, with the improvements below)
npx skills install PaulBratslavsky/tcr-skill --skill tcr-kentbeck

# Install tcr-kentbeck (original version)
npx skills install xpepper/tcr-skill --skill tcr-kentbeck

# Install tcr
npx skills install xpepper/tcr-skill --skill tcr
```

Alternatively, use the pre-packaged `.skill` files:

```bash
# Available at repo root: tcr.skill, tcr-kentbeck.skill
```

Refer to your agent's documentation for the exact skills directory.

---

## Improvements in this fork (Paul Bratslavsky)

This fork ([PaulBratslavsky/tcr-skill](https://github.com/PaulBratslavsky/tcr-skill)) changes only `tcr-kentbeck`. The git-gamble based `tcr` skill is unchanged. The changes come from running the skill step by step on a FizzBuzz kata, which turned up these issues:

- **`tcr.sh` helper.** A small, portable bash script (git is the only dependency) that sits next to `SKILL.md`. It runs the full test suite (auto-detected, from `$TCR_TEST_CMD`, or passed after `--`), commits on green, and fully reverts and logs on red. The agent runs it instead of deciding commit or revert by hand, so it can't "forget" to revert or quietly keep a red change.
- **Full revert.** The original `git restore .` left new untracked files and staged edits in place, so a red step that created a file stayed red after the "revert". The revert is now `git reset --hard HEAD` plus `git clean -fd` (git-ignored files are kept). History is never rewritten; only uncommitted work is discarded.
- **Failure log can't be erased.** Before, an uncommitted log entry was wiped out by the next revert, which broke the "append-only" promise when two reds came in a row. `tcr.sh` now backs up the log, leaves it out of the clean step, restores it, appends the new entry, and commits the log right away.
- **Correct "failing test first" guidance.** In TCR, red always reverts, so a failing test can never be committed on its own. The skill now says to add each test together with its minimal implementation, and points to the `tcr` (git-gamble `--red`) skill for an explicit red phase.
- **Empty test suite.** On a new project, "no tests collected" (pytest exit 5, Jest/Vitest "No tests found") is reported as exit code `3` and nothing is reverted. `--allow-empty-suite` lets you commit scaffolding.
- Richer log entries: the attempted change, test command and exit code, the commit it reverted to, the discarded diffstat and new files, and the tail of the test output.

`tcr.sh -h` lists all options. Exit codes: `0` green, `1` red, `2` setup error, `3` empty suite.

---

## Credits

- **[xpepper/tcr-skill](https://github.com/xpepper/tcr-skill)** by Pietro Di Bello: the original agent-agnostic adaptation and both skills (`tcr`, `tcr-kentbeck`), the evals, and the packaging this fork builds on.
- **[KentBeck/TCRSkill](https://github.com/KentBeck/TCRSkill)** by Kent Beck: the original Cursor TCR skill that `tcr-kentbeck` is adapted from.
- **[test && commit || revert](https://medium.com/@kentbeck_7670/test-commit-revert-870bbd756864)** by Kent Beck: the post that introduced TCR. Beck credits Oddmund Strømme with the "revert" half, from a code camp with Lars Barlindhaug and Ole Johannessen.
- **[git-gamble](https://git-gamble.is-cool.dev/)**: the tool behind the `tcr` skill.

Licensed under the MIT License (see [LICENSE](LICENSE)); the original copyright notice is kept.

---

## Evals

The `evals/` directory contains test prompts used to validate the skills.

---

## Resources

- [TCR original post by Kent Beck](https://medium.com/@kentbeck_7670/test-commit-revert-870bbd756864)
- [KentBeck/TCRSkill](https://github.com/KentBeck/TCRSkill/) — Kent Beck's original Cursor skill
- [git-gamble](https://git-gamble.is-cool.dev/) — the tool that powers the `tcr` skill
- [Agent Skills specification](https://agentskills.io/specification)
