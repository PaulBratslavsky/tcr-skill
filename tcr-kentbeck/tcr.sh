#!/usr/bin/env bash
# tcr.sh - test && commit || revert, with a failure log that a revert can't erase.
#
# Part of the tcr-kentbeck agent skill. Only needs git and bash (3.2+).
#
# Usage:
#   tcr.sh -m "Describe the change" [options] [--] [test command ...]
#
# Options:
#   -m, --message MSG      Commit message on green; recorded as the attempted change on red.
#   -l, --log FILE         Failure log path, relative to the repo root (default: tcr-failure-log.md).
#       --allow-empty-suite  Treat "no tests collected" as green (scaffolding a new project only).
#       --no-log-commit    On red, append the log entry but leave it uncommitted
#                          (it is still preserved across later reverts).
#   -h, --help             Show this help.
#
# Test command: the arguments after the options, or $TCR_TEST_CMD, or auto-detected
# (package.json "test" script, Makefile "test" target, Cargo.toml, go.mod, pytest
# config/files, Maven, Gradle).
#
# Exit codes: 0 green (committed, or nothing to commit), 1 red (reverted and logged),
#             2 usage/setup error, 3 empty test suite (nothing committed or reverted).

set -u

LOG_FILE="${TCR_LOG:-tcr-failure-log.md}"
MESSAGE=""
ALLOW_EMPTY=0
LOG_COMMIT=1
OUTPUT_LINES="${TCR_OUTPUT_LINES:-40}"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }
say() { printf 'tcr: %s\n' "$*" >&2; }
die() { say "$*"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) [ $# -ge 2 ] || die "$1 needs a value"; MESSAGE="$2"; shift 2 ;;
    -l|--log) [ $# -ge 2 ] || die "$1 needs a value"; LOG_FILE="$2"; shift 2 ;;
    --allow-empty-suite) ALLOW_EMPTY=1; shift ;;
    --no-log-commit) LOG_COMMIT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (use -- before a test command that starts with -)" ;;
    *) break ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT" || die "cannot cd to $ROOT"
git rev-parse --verify -q HEAD >/dev/null \
  || die "the repository has no commits yet; make an initial (scaffolding) commit first"

case "$LOG_FILE" in /*|../*) die "--log must be a path inside the repository" ;; esac

# Protect this script too if it was copied into the repo without being committed.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
ROOT_REAL="$(pwd -P)"
SCRIPT_REL=""
case "$SCRIPT_PATH" in "$ROOT_REAL"/*) SCRIPT_REL="${SCRIPT_PATH#"$ROOT_REAL"/}" ;; esac

has_test_script() {
  # "scripts": { ... "test": ... } - a plain grep keeps this dependency-free.
  grep -Eq '"test"[[:space:]]*:' package.json 2>/dev/null
}

detect_test_cmd() {
  if [ -f package.json ] && has_test_script; then
    if [ -f pnpm-lock.yaml ]; then echo "pnpm test"
    elif [ -f yarn.lock ]; then echo "yarn test"
    else echo "npm test"; fi
  elif [ -f Makefile ] && grep -Eq '^test[[:space:]]*:' Makefile; then echo "make test"
  elif [ -f Cargo.toml ]; then echo "cargo test"
  elif [ -f go.mod ]; then echo "go test ./..."
  elif [ -f pytest.ini ] || [ -f conftest.py ] || [ -f tox.ini ] \
       || grep -qs '\[tool.pytest' pyproject.toml || grep -qs '\[tool:pytest\]' setup.cfg \
       || [ -n "$(git ls-files '*test_*.py' '*_test.py' 2>/dev/null | head -n 1)" ]; then
    if command -v pytest >/dev/null 2>&1; then echo "pytest"; else echo "python3 -m pytest"; fi
  elif [ -f pom.xml ]; then echo "mvn -q test"
  elif [ -x gradlew ]; then echo "./gradlew test"
  else return 1; fi
}

if [ $# -gt 0 ]; then
  TEST_DESC="$*"
  run_tests() { "$@"; }
else
  TEST_CMD="${TCR_TEST_CMD:-}"
  if [ -z "$TEST_CMD" ]; then
    TEST_CMD="$(detect_test_cmd)" \
      || die "could not detect the test command; pass it after -- or set TCR_TEST_CMD"
  fi
  TEST_DESC="$TEST_CMD"
  run_tests() { bash -c "$TEST_CMD"; }
fi

OUT="$(mktemp "${TMPDIR:-/tmp}/tcr-out.XXXXXX")" || die "mktemp failed"
LOG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/tcr-log.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$OUT" "$LOG_BACKUP"' EXIT

say "running: $TEST_DESC"
run_tests "$@" >"$OUT" 2>&1
RC=$?
cat "$OUT"

# Empty suite: pytest exits 5; jest/vitest print "No tests found" / "No test files found".
EMPTY=0
case "$TEST_DESC" in *pytest*) [ "$RC" -eq 5 ] && EMPTY=1 ;; esac
if [ "$RC" -ne 0 ] && grep -Eq 'No tests found|No test files found' "$OUT"; then EMPTY=1; fi

if [ "$EMPTY" -eq 1 ]; then
  if [ "$ALLOW_EMPTY" -eq 1 ]; then
    say "no tests collected; --allow-empty-suite given, treating as green"
    RC=0
  else
    say "no tests collected (exit $RC). Nothing committed or reverted."
    say "Add a test together with its minimal implementation, or rerun with --allow-empty-suite for scaffolding."
    exit 3
  fi
fi

if [ "$RC" -eq 0 ]; then
  git add -A || die "git add failed"
  if git diff --cached --quiet; then
    say "GREEN - nothing to commit"
    exit 0
  fi
  [ -n "$MESSAGE" ] || { MESSAGE="tcr: tests pass"; say "no -m given; using '$MESSAGE'"; }
  git commit -q -m "$MESSAGE" || die "tests passed but git commit failed (hooks or identity?); changes left staged"
  say "GREEN - committed $(git rev-parse --short HEAD): $MESSAGE"
  exit 0
fi

# ---- RED: record what is being thrown away, revert fully, keep the log ----
STAT="$( { git diff HEAD --stat; git ls-files --others --exclude-standard | sed 's/^/new file: /'; } 2>/dev/null \
         | grep -v -F -- "$LOG_FILE" )"
HAD_LOG=0
if [ -f "$LOG_FILE" ]; then cp "$LOG_FILE" "$LOG_BACKUP" && HAD_LOG=1; fi

git reset -q --hard HEAD || die "git reset --hard failed"
REVERTED_TO="$(git log -1 --format='%h %s')"
if [ -n "$SCRIPT_REL" ]; then
  git clean -q -fd -e "/$LOG_FILE" -e "/$SCRIPT_REL"
else
  git clean -q -fd -e "/$LOG_FILE"
fi

if [ "$HAD_LOG" -eq 1 ]; then
  cp "$LOG_BACKUP" "$LOG_FILE"
else
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '# TCR failure log\n\nAppend-only. One entry per reverted step.\n' >"$LOG_FILE"
fi

# Backticks below are literal Markdown, not command substitution.
# shellcheck disable=SC2016
{
  printf '\n## %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- **Attempted:** %s\n' "${MESSAGE:-(no description given)}"
  printf -- '- **Test command:** `%s` (exit %s)\n' "$TEST_DESC" "$RC"
  printf -- '- **Reverted to:** %s\n' "$REVERTED_TO"
  if [ -n "$STAT" ]; then
    printf -- '- **Discarded changes:**\n\n```text\n%s\n```\n\n' "$STAT"
  fi
  printf -- '- **Test output (last %s lines):**\n\n```text\n' "$OUTPUT_LINES"
  tail -n "$OUTPUT_LINES" "$OUT"
  printf '```\n\n'
  printf -- '- **Next:** (fill in or leave for the next attempt)\n'
} >>"$LOG_FILE"

if [ "$LOG_COMMIT" -eq 1 ]; then
  if ! { git add -- "$LOG_FILE" && git commit -q -m "tcr: log failure: ${MESSAGE:-red step}" -- "$LOG_FILE"; }; then
    say "warning: could not commit $LOG_FILE (it is still saved in the working tree)"
  fi
fi
say "RED - reverted to ${REVERTED_TO%% *}; logged in $LOG_FILE (HEAD now $(git rev-parse --short HEAD))"
exit 1
