#!/usr/bin/env bash
# Pure Core and minimal CLI wiring specs for pr-gate:
# 1. Part 1: lib/auto-review-mark.sh & lib/pr-gate-core.sh (zero I/O)
# 2. Pure Core: evaluate_ci_state, evaluate_review_state, count_auto_review_finding_rounds,
#    touches_protected, extract_hotfix_debt_issue, decide_pr_gate
# 3. Part 2: >2.5 MB JSON payloads without Argument list too long
# 4. Part 4: at most 2 minimal CLI wiring smoke checks (no scratch git repositories)
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
pass_count=0
fail_count=0

pass() {
  printf 'ok    %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail_case() {
  printf 'FAIL  %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  fail=1
  fail_count=$((fail_count + 1))
}

check() { # $1 = test name, $2 = want, $3 = got
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail_case "$1" "$2" "$3"
  fi
}

check_rc() { # $1 = test name, $2 = want_rc, $3 = got_rc
  check "$1" "$2" "$3"
}

check_prefix() { # $1 = test name, $2 = prefix, $3 = got
  case "$3" in
    "$2"*) pass "$1" ;;
    *) fail_case "$1" "${2}*" "$3" ;;
  esac
}

MARK="${MARK:-$here/lib/auto-review-mark.sh}"
CORE="${CORE:-$here/lib/pr-gate-core.sh}"
WATCHER="${WATCHER:-$here/bin/auto-review-watch.sh}"
GATE="${GATE:-$here/bin/pr-gate.sh}"

# Source Pure Core libraries directly when present; fall back to bin scripts
# only prior to extraction so an earlier change/#384 assertions fail on missing behaviour
# rather than undefined symbol stubs while Part 1 extraction assertions fail.
if [ -f "$MARK" ]; then
  # shellcheck disable=SC1090
  . "$MARK"
fi
if [ -f "$CORE" ]; then
  # shellcheck disable=SC1090
  . "$CORE"
else
  if [ -f "$WATCHER" ]; then
    # shellcheck disable=SC1090
    . "$WATCHER"
  fi
  if [ -f "$GATE" ]; then
    # shellcheck disable=SC1090
    . "$GATE"
  fi
fi
set +e +o pipefail 2>/dev/null || true

run_evaluate_ci_state() {
  if declare -F evaluate_ci_state >/dev/null 2>&1; then
    evaluate_ci_state "$@"
  else
    printf '__UNDEFINED_evaluate_ci_state__\n'
  fi
}

run_evaluate_review_state() {
  if declare -F evaluate_review_state >/dev/null 2>&1; then
    evaluate_review_state "$@"
  else
    printf '__UNDEFINED_evaluate_review_state__\n'
  fi
}

run_decide_pr_gate() {
  if declare -F decide_pr_gate >/dev/null 2>&1; then
    decide_pr_gate "$@"
  else
    printf '__UNDEFINED_decide_pr_gate__\n'
  fi
}

run_touches_protected() {
  if declare -F touches_protected >/dev/null 2>&1; then
    touches_protected "$@"
  else
    printf '__UNDEFINED_touches_protected__\n'
  fi
}

run_count_auto_review_finding_rounds() {
  if declare -F count_auto_review_finding_rounds >/dev/null 2>&1; then
    count_auto_review_finding_rounds "$@"
  elif declare -F count_finding_rounds >/dev/null 2>&1; then
    count_finding_rounds "$@"
  else
    printf '__UNDEFINED_count_auto_review_finding_rounds__\n'
  fi
}

run_extract_hotfix_debt_issue() {
  if declare -F extract_hotfix_debt_issue >/dev/null 2>&1; then
    extract_hotfix_debt_issue "$@"
  else
    printf '__UNDEFINED_extract_hotfix_debt_issue__\n'
    return 127
  fi
}

run_auto_review_commit_sha() {
  if declare -F auto_review_commit_sha >/dev/null 2>&1; then
    auto_review_commit_sha "$@"
  else
    printf '__UNDEFINED_auto_review_commit_sha__\n'
  fi
}

run_auto_review_verdict() {
  if declare -F auto_review_verdict >/dev/null 2>&1; then
    auto_review_verdict "$@"
  else
    printf '__UNDEFINED_auto_review_verdict__\n'
  fi
}

run_filter_auto_reviews() {
  if declare -F filter_auto_reviews >/dev/null 2>&1; then
    filter_auto_reviews "$@"
  else
    printf '__UNDEFINED_filter_auto_reviews__\n'
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# 0. Part 1: Shared auto-review-mark.sh, Pure Core pr-gate-core.sh, Zero-I/O
# ═════════════════════════════════════════════════════════════════════════════

if [ -f "$MARK" ]; then
  pass "part1: lib/auto-review-mark.sh exists"
else
  fail_case "part1: lib/auto-review-mark.sh exists" "file present" "missing: $MARK"
fi

if [ -f "$CORE" ]; then
  pass "part1: lib/pr-gate-core.sh exists"
else
  fail_case "part1: lib/pr-gate-core.sh exists" "file present" "missing: $CORE"
fi

if [ -f "$MARK" ]; then
  mark_syms_ok=0
  (
    set -u
    # shellcheck disable=SC1090
    . "$MARK"
    declare -F auto_review_commit_sha >/dev/null 2>&1 &&
      declare -F auto_review_verdict >/dev/null 2>&1 &&
      declare -F filter_auto_reviews >/dev/null 2>&1
  ) && mark_syms_ok=1
  check "part1: auto-review-mark.sh standalone defines mark helpers" "1" "$mark_syms_ok"

  mark_io_hits="$(grep -v '^[[:space:]]*#' "$MARK" | grep -nE '(^|[[:space:];|&(])(gh|git|docker|systemctl)([[:space:]]|$)' || true)"
  check "part1: auto-review-mark.sh has zero external I/O commands" "" "$mark_io_hits"
else
  fail_case "part1: auto-review-mark.sh standalone defines mark helpers" "1" "0 (missing $MARK)"
  fail_case "part1: auto-review-mark.sh has zero external I/O commands" "zero I/O calls" "missing $MARK"
fi

if [ -f "$CORE" ]; then
  core_syms_ok=0
  (
    set -u
    # shellcheck disable=SC1090
    . "$CORE"
    declare -F evaluate_ci_state >/dev/null 2>&1 &&
      declare -F evaluate_review_state >/dev/null 2>&1 &&
      (declare -F count_auto_review_finding_rounds >/dev/null 2>&1 || declare -F count_finding_rounds >/dev/null 2>&1) &&
      declare -F touches_protected >/dev/null 2>&1 &&
      declare -F extract_hotfix_debt_issue >/dev/null 2>&1 &&
      declare -F evaluate_executor_ledger >/dev/null 2>&1 &&
      declare -F owner_approved_head >/dev/null 2>&1 &&
      declare -F decide_pr_gate >/dev/null 2>&1 &&
      declare -F auto_review_commit_sha >/dev/null 2>&1 &&
      declare -F auto_review_verdict >/dev/null 2>&1 &&
      declare -F filter_auto_reviews >/dev/null 2>&1
  ) && core_syms_ok=1
  check "part1: pr-gate-core.sh standalone defines all pure core + mark functions" "1" "$core_syms_ok"

  core_io_hits="$(grep -v '^[[:space:]]*#' "$CORE" | grep -nE '(^|[[:space:];|&(])(gh|git|docker|systemctl)([[:space:]]|$)' || true)"
  check "part1: pr-gate-core.sh has zero external I/O commands" "" "$core_io_hits"

  runtime_zero_io=0
  (
    set -u
    gh() { printf 'UNEXPECTED_IO:gh\n' >&2; return 99; }
    git() { printf 'UNEXPECTED_IO:git\n' >&2; return 99; }
    docker() { printf 'UNEXPECTED_IO:docker\n' >&2; return 99; }
    systemctl() { printf 'UNEXPECTED_IO:systemctl\n' >&2; return 99; }
    # shellcheck disable=SC1090
    . "$CORE"
    r1="$(evaluate_ci_state '{"workflow_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}' '{"state":"success","statuses":[]}')"
    r2="$(evaluate_review_state 1 "abc1234" '[{"commit_id":"abc1234","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"
    r3="$(touches_protected 'src/app.sh' '/install.sh @hanzhad')"
    r4="$(decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","headRefOid":"abc1234","labels":[],"files":[{"path":"src/app.sh"}],"reviews":[]}' "$r1" "$r2" 0 "$r3")"
    [ "$r1" = "settled_green" ] && [ "$r2" = "clean" ] && [ -z "$r3" ] && [ "$r4" = "0|OK|1|gate passed" ]
  ) && runtime_zero_io=1
  check "part1: pr-gate-core.sh evaluates in memory with gh/git/docker/systemctl blocked" "1" "$runtime_zero_io"
else
  fail_case "part1: pr-gate-core.sh standalone defines all pure core + mark functions" "1" "0 (missing $CORE)"
  fail_case "part1: pr-gate-core.sh has zero external I/O commands" "zero I/O calls" "missing $CORE"
  fail_case "part1: pr-gate-core.sh evaluates in memory with gh/git/docker/systemctl blocked" "1" "0 (missing $CORE)"
fi

if grep -q 'auto-review-mark\.sh' "$WATCHER" &&
   ! grep -qE '^[[:space:]]*filter_auto_reviews[[:space:]]*\(\)' "$WATCHER" &&
   grep -q 'auto_review_verdict' "$WATCHER" &&
   ! grep -qF "'**No findings.'" "$WATCHER"; then
  pass "part1: auto-review-watch.sh sources auto-review-mark.sh without duplicate parsers"
else
  fail_case "part1: auto-review-watch.sh sources auto-review-mark.sh without duplicate parsers" \
    "sources auto-review-mark.sh, uses auto_review_verdict, and drops duplicate filter_auto_reviews()" "not yet refactored"
fi

watcher_compat_ok=0
(
  # shellcheck disable=SC1090
  . "$WATCHER"
  declare -F filter_auto_reviews >/dev/null 2>&1 &&
    declare -F auto_review_verdict >/dev/null 2>&1
) && watcher_compat_ok=1
check "part1: sourcing auto-review-watch.sh exposes mark helpers" "1" "$watcher_compat_ok"

if grep -q 'pr-gate-core\.sh' "$GATE" &&
   ! grep -qE '^[[:space:]]*(evaluate_ci_state|evaluate_review_state|touches_protected|extract_hotfix_debt_issue|decide_pr_gate)[[:space:]]*\(\)' "$GATE"; then
  pass "part1: pr-gate.sh sources pr-gate-core.sh without inline pure core functions"
else
  fail_case "part1: pr-gate.sh sources pr-gate-core.sh without inline pure core functions" \
    "sources pr-gate-core.sh and moves pure functions out" "pure functions still inline or missing source"
fi

gate_compat_ok=0
(
  # shellcheck disable=SC1090
  . "$GATE"
  declare -F evaluate_ci_state >/dev/null 2>&1 &&
    declare -F evaluate_review_state >/dev/null 2>&1 &&
    declare -F touches_protected >/dev/null 2>&1 &&
    declare -F extract_hotfix_debt_issue >/dev/null 2>&1 &&
    declare -F decide_pr_gate >/dev/null 2>&1
) && gate_compat_ok=1
check "part1: source bin/pr-gate.sh preserves pure core symbols for callers" "1" "$gate_compat_ok"


# ═════════════════════════════════════════════════════════════════════════════
# 1. Pure Core auto-review-mark.sh: commit SHA, verdict, and filter_auto_reviews
# ═════════════════════════════════════════════════════════════════════════════

check "auto_review_commit_sha: commit_id field" \
  "abc1234" \
  "$(run_auto_review_commit_sha '{"commit_id":"abc1234","body":"**No findings.**"}')"

check "auto_review_commit_sha: commit.oid GraphQL field" \
  "def5678" \
  "$(run_auto_review_commit_sha '{"commit":{"oid":"def5678"},"body":"**No findings.**"}')"

check "auto_review_commit_sha: embedded auto-review mark fallback when commit_id is null" \
  "fedcba987654" \
  "$(run_auto_review_commit_sha '{"commit_id":null,"body":"**No findings.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"fedcba987654\",\"verdict\":\"clean\",\"findings\":0} -->"}')"

check "auto_review_commit_sha: footer Commit fallback when commit_id is null" \
  "1122334" \
  "$(run_auto_review_commit_sha '{"commit_id":null,"body":"**No findings.**\n\n---\n_Automated review. Not an approval._ • Commit: 1122334"}')"

check "auto_review_commit_sha: empty when no commit info exists" \
  "" \
  "$(run_auto_review_commit_sha '{"commit_id":null,"body":"Looks good"}')"

check "auto_review_verdict: clean on No findings" \
  "clean" \
  "$(run_auto_review_verdict "**No findings.**")"

check "auto_review_verdict: clean on Skipped — generated files only." \
  "clean" \
  "$(run_auto_review_verdict "**Skipped — generated files only.**")"

check "auto_review_verdict: clean with leading CRLF blank lines" \
  "clean" \
  "$(run_auto_review_verdict "$(printf '\r\n\r\n**No findings.**\r\n')")"

check "auto_review_verdict: refused_size on Not reviewed." \
  "refused_size" \
  "$(run_auto_review_verdict "**Not reviewed.** — diff too large")"

check "auto_review_verdict: skipped_low_risk on Skipped — low-risk paths only." \
  "skipped_low_risk" \
  "$(run_auto_review_verdict "**Skipped — low-risk paths only.**")"

check "auto_review_verdict: findings on 1 finding" \
  "findings" \
  "$(run_auto_review_verdict "**1 finding.** — see inline")"

check "filter_auto_reviews: handles null body in earlier review gracefully" \
  '{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}' \
  "$(run_filter_auto_reviews '[{"commit_id":"older456","body":null},{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' "head123")"

check "filter_auto_reviews: ignores human review and picks latest matching auto-review via machine mark" \
  '{"commit_id":null,"body":"**No findings.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"head1234567\",\"verdict\":\"clean\",\"findings\":0} -->"}' \
  "$(run_filter_auto_reviews '[{"commit_id":"head1234567","body":"LGTM"},{"commit_id":null,"body":"**1 finding.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"head1234567\",\"verdict\":\"findings\",\"findings\":1} -->"},{"commit_id":null,"body":"**No findings.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"head1234567\",\"verdict\":\"clean\",\"findings\":0} -->"}]' "head1234567")"

check "filter_auto_reviews: returns empty when only other head SHA was reviewed" \
  "" \
  "$(run_filter_auto_reviews '[{"commit_id":"other999","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' "head1234567")"


# ═════════════════════════════════════════════════════════════════════════════
# 2. evaluate_ci_state <runs_json> <status_json> [pr_json]
# ═════════════════════════════════════════════════════════════════════════════

# 2.1 Unreadable input
check "evaluate_ci_state: invalid runs json" \
  "unreadable:runs" \
  "$(run_evaluate_ci_state "not-json" '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: runs json missing workflow_runs key" \
  "unreadable:runs" \
  "$(run_evaluate_ci_state '{"invalid_key":1}' '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: empty runs json" \
  "unreadable:runs" \
  "$(run_evaluate_ci_state "" '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: invalid status json" \
  "unreadable:status" \
  "$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' "not-json")"

check "evaluate_ci_state: status json missing statuses and state" \
  "unreadable:status" \
  "$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' '{"invalid_key":1}')"

check "evaluate_ci_state: empty status json" \
  "unreadable:status" \
  "$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' "")"

# 2.2 Pending
check "evaluate_ci_state: workflow run in_progress" \
  "pending" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"build","status":"in_progress","conclusion":null}]}' '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: workflow run queued" \
  "pending" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"lint","status":"queued","conclusion":null}]}' '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: commit status pending" \
  "pending" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"build","status":"completed","conclusion":"success"}]}' '{"state":"pending","total_count":1,"statuses":[{"context":"ci/status","state":"pending"}]}')"

check "evaluate_ci_state: mixed completed and in_progress workflow runs" \
  "pending" \
  "$(run_evaluate_ci_state '{"total_count":2,"workflow_runs":[{"name":"test","status":"completed","conclusion":"success"},{"name":"build","status":"in_progress","conclusion":null}]}' '{"state":"success","total_count":0,"statuses":[]}')"

# 2.3 Failed
check "evaluate_ci_state: workflow run failure" \
  "failed:check" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"check","status":"completed","conclusion":"failure"}]}' '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: workflow run timed_out" \
  "failed:lint" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"lint","status":"completed","conclusion":"timed_out"}]}' '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: workflow run cancelled" \
  "failed:e2e" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"e2e","status":"completed","conclusion":"cancelled"}]}' '{"state":"success","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: commit status failure" \
  "failed:codecov" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"build","status":"completed","conclusion":"success"}]}' '{"state":"failure","total_count":1,"statuses":[{"context":"codecov","state":"failure"}]}')"

check "evaluate_ci_state: commit status error" \
  "failed:deploy" \
  "$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' '{"state":"error","total_count":1,"statuses":[{"context":"deploy","state":"error"}]}')"

# 2.4 Settled no CI & Settled green
check "evaluate_ci_state: 0 workflow runs and 0 commit statuses" \
  "settled_no_ci" \
  "$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' '{"state":"pending","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: workflow runs succeeded and 0 commit statuses" \
  "settled_green" \
  "$(run_evaluate_ci_state '{"total_count":1,"workflow_runs":[{"name":"check","status":"completed","conclusion":"success"}]}' '{"state":"pending","total_count":0,"statuses":[]}')"

check "evaluate_ci_state: workflow runs succeeded or skipped with success commit status" \
  "settled_green" \
  "$(run_evaluate_ci_state '{"total_count":2,"workflow_runs":[{"name":"test","status":"completed","conclusion":"success"},{"name":"deploy","status":"completed","conclusion":"skipped"}]}' '{"state":"success","total_count":1,"statuses":[{"context":"ci","state":"success"}]}')"

check "evaluate_ci_state: 0 workflow runs and success commit status" \
  "settled_green" \
  "$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' '{"state":"success","total_count":1,"statuses":[{"context":"ci","state":"success"}]}')"

# 2.5 an earlier change: changeset-release/* bot PRs with pull_request action_required + passing Verify
mk_ci_pr() { # $1 = headRefName, $2 = author.login, $3 = headRefOid
  jq -nc --arg b "$1" --arg a "$2" --arg s "${3:-head384sha}" \
    '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",headRefName:$b,headRefOid:$s,labels:[],files:[{path:"CHANGELOG.md"}],reviews:[],author:{login:$a},body:""}'
}

EMPTY_STATUS='{"state":"pending","total_count":0,"statuses":[]}'
PR_CR_APP="$(mk_ci_pr "changeset-release/master" "app/github-actions" "head384sha")"
PR_CR_BOT="$(mk_ci_pr "changeset-release/master" "github-actions[bot]" "head384sha")"
PR_CR_V2="$(mk_ci_pr "changeset-release/v2.1" "app/github-actions" "head384sha")"

RUNS_CR_REL_VERIFY='{"total_count":2,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'

RUNS_CR_VERIFY='{"total_count":2,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Verify","event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'

RUNS_CR_MULTI_AR='{"total_count":3,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Deploy preview","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'

RUNS_CR_ONLY_AR='{"total_count":1,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'

# Positive cases
check "evaluate_ci_state an earlier change: changeset-release/master by app/github-actions + action_required + workflow_dispatch Release verify -> settled_green" \
  "settled_green" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$PR_CR_APP")"

check "evaluate_ci_state an earlier change: changeset-release/master by github-actions[bot] + action_required + workflow_dispatch Verify -> settled_green" \
  "settled_green" \
  "$(run_evaluate_ci_state "$RUNS_CR_VERIFY" "$EMPTY_STATUS" "$PR_CR_BOT")"

check "evaluate_ci_state an earlier change: wildcard changeset-release/v2.1 by app/github-actions + workflow_dispatch Release verify -> settled_green" \
  "settled_green" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$PR_CR_V2")"

check "evaluate_ci_state an earlier change: multiple pull_request action_required runs ignored when workflow_dispatch Release verify succeeds" \
  "settled_green" \
  "$(run_evaluate_ci_state "$RUNS_CR_MULTI_AR" "$EMPTY_STATUS" "$PR_CR_APP")"

check "evaluate_ci_state an earlier change: commit status Verify state=success satisfies verify requirement" \
  "settled_green" \
  "$(run_evaluate_ci_state "$RUNS_CR_ONLY_AR" '{"state":"success","total_count":1,"statuses":[{"context":"Verify","state":"success"}]}' "$PR_CR_APP")"

check "evaluate_ci_state an earlier change: commit status Release verify state=success satisfies verify requirement" \
  "settled_green" \
  "$(run_evaluate_ci_state "$RUNS_CR_ONLY_AR" '{"state":"success","total_count":1,"statuses":[{"context":"Release verify","state":"success"}]}' "$PR_CR_APP")"

# Negative & boundary cases
check "evaluate_ci_state an earlier change: changeset-release/master action_required with NO Verify run -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_ONLY_AR" "$EMPTY_STATUS" "$PR_CR_APP")"

RUNS_CR_NON_VERIFY_SUCCESS='{"total_count":2,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Lint","event":"pull_request","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'
check "evaluate_ci_state an earlier change: non-Verify pull_request success + non-Verify status do not waive action_required" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_NON_VERIFY_SUCCESS" '{"state":"success","total_count":1,"statuses":[{"context":"codecov","state":"success"}]}' "$PR_CR_APP")"

RUNS_CR_STALE_VERIFY='{"total_count":2,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"old000sha"}
]}'
check "evaluate_ci_state an earlier change: workflow_dispatch Verify on different head_sha does not waive action_required" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_STALE_VERIFY" "$EMPTY_STATUS" "$PR_CR_APP")"

RUNS_CR_VERIFY_FAILED='{"total_count":2,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"completed","conclusion":"failure","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'
check_prefix "evaluate_ci_state an earlier change: failed Release verify stays failed" \
  "failed:" \
  "$(run_evaluate_ci_state "$RUNS_CR_VERIFY_FAILED" "$EMPTY_STATUS" "$PR_CR_APP")"

RUNS_CR_VERIFY_PENDING='{"total_count":2,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"in_progress","conclusion":null,"head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'
check "evaluate_ci_state an earlier change: in_progress Release verify evaluates pending" \
  "pending" \
  "$(run_evaluate_ci_state "$RUNS_CR_VERIFY_PENDING" "$EMPTY_STATUS" "$PR_CR_APP")"

RUNS_CR_WITH_FAILURE='{"total_count":3,"workflow_runs":[
  {"name":"CI","event":"pull_request","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Lint","event":"pull_request","status":"completed","conclusion":"failure","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'
check "evaluate_ci_state an earlier change: non-action_required failure is NOT ignored even when Release verify passes" \
  "failed:Lint" \
  "$(run_evaluate_ci_state "$RUNS_CR_WITH_FAILURE" "$EMPTY_STATUS" "$PR_CR_APP")"

RUNS_CR_DISPATCH_AR='{"total_count":2,"workflow_runs":[
  {"name":"Deploy","event":"workflow_dispatch","status":"completed","conclusion":"action_required","head_branch":"changeset-release/master","head_sha":"head384sha"},
  {"name":"Release verify","event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"changeset-release/master","head_sha":"head384sha"}
]}'
check "evaluate_ci_state an earlier change: non-pull_request action_required is NOT ignored" \
  "failed:Deploy" \
  "$(run_evaluate_ci_state "$RUNS_CR_DISPATCH_AR" "$EMPTY_STATUS" "$PR_CR_APP")"

check "evaluate_ci_state an earlier change: failing commit status still fails even when Release verify passes" \
  "failed:deploy" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" '{"state":"failure","total_count":1,"statuses":[{"context":"deploy","state":"failure"}]}' "$PR_CR_APP")"

check "evaluate_ci_state an earlier change: normal feature branch by app/github-actions stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "feat/my-branch" "app/github-actions" "head384sha")")"

check "evaluate_ci_state an earlier change: nested branch feature/changeset-release/master stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "feature/changeset-release/master" "app/github-actions" "head384sha")")"

check "evaluate_ci_state an earlier change: bare branch changeset-release without slash stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "changeset-release" "app/github-actions" "head384sha")")"

check "evaluate_ci_state an earlier change: human author on changeset-release/master stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "changeset-release/master" "hanzhad" "head384sha")")"

check "evaluate_ci_state an earlier change: agent author on changeset-release/master stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "changeset-release/master" "acme-agent" "head384sha")")"

check "evaluate_ci_state an earlier change: different bot app/dependabot on changeset-release/master stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "changeset-release/master" "app/dependabot" "head384sha")")"

check "evaluate_ci_state an earlier change: lookalike author github-actions-helper stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$(mk_ci_pr "changeset-release/master" "github-actions-helper" "head384sha")")"

check "evaluate_ci_state an earlier change: 2-arg call without PR context stays strict -> failed:CI" \
  "failed:CI" \
  "$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS")"


# ═════════════════════════════════════════════════════════════════════════════
# 3. evaluate_review_state <auto_review_installed:0|1> <head_sha> <reviews_json> <base_merge_ok:0|1>
# ═════════════════════════════════════════════════════════════════════════════

check "evaluate_review_state: not required when auto_review_installed is 0" \
  "not_required" \
  "$(run_evaluate_review_state 0 "head123" '[]' 0)"

check "evaluate_review_state: not required when auto_review_installed is 0 even with reviews" \
  "not_required" \
  "$(run_evaluate_review_state 0 "head123" '[{"commit_id":"head123","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: wait_review when reviews empty" \
  "wait_review" \
  "$(run_evaluate_review_state 1 "head123" '[]' 0)"

check "evaluate_review_state: wait_review when no automated review marker exists" \
  "wait_review" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"Looks fine to me."}]' 0)"

check "evaluate_review_state: wait_review when commit_id does not match head_sha and base_merge_ok is 0" \
  "wait_review" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"older456","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: clean when commit_id does not match head_sha but base_merge_ok is 1" \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"older456","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 1)"

check "evaluate_review_state: clean with No findings." \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: clean with No findings. followed by details" \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**No findings.** — this pull request has an empty diff, so there is nothing to review.\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: clean with Skipped — generated files only." \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**Skipped — generated files only.**\n\n_Not read — generated files._\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: clean when review has leading blank lines" \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"\n\n**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: refused_size with Not reviewed." \
  "refused_size" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**Not reviewed.** — this diff is 1200 lines.\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: skipped_low_risk with Skipped — low-risk paths only." \
  "skipped_low_risk" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**Skipped — low-risk paths only.**\n\n- `README.md`\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: findings with 1 finding" \
  "findings" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**1 finding.** — see below:\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: findings with 2 findings" \
  "findings" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**2 findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: findings with any other text" \
  "findings" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"Please update tests and docs.\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: latest review takes precedence" \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"head123","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: clean with footer commit sha fallback when commit_id is null" \
  "clean" \
  "$(run_evaluate_review_state 1 "head1234567" '[{"commit_id":null,"body":"**No findings.**\n\n---\n_Automated review. Not an approval._ • Commit: head123"}]' 0)"

check "evaluate_review_state: handles null body in earlier review gracefully" \
  "clean" \
  "$(run_evaluate_review_state 1 "head123" '[{"commit_id":"older456","body":null},{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"}]' 0)"

check "evaluate_review_state: clean with machine mark fallback when commit_id is null" \
  "clean" \
  "$(run_evaluate_review_state 1 "head1234567" '[{"commit_id":null,"body":"**No findings.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"head1234567\",\"verdict\":\"clean\",\"findings\":0,\"ts\":1730889600} -->"}]' 0)"


# ═════════════════════════════════════════════════════════════════════════════
# 4. decide_pr_gate <pr_json> <ci_state> <review_state> <cross_area:0|1> [protected_hits]
# ═════════════════════════════════════════════════════════════════════════════

BASE_PR='{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[{"path":"src/app.sh"}],"reviews":[]}'

check "decide_pr_gate: closed pr" \
  "3|NOT_OPEN|0|pull request is not open" \
  "$(run_decide_pr_gate '{"state":"CLOSED","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: merged pr" \
  "3|NOT_OPEN|0|pull request is not open" \
  "$(run_decide_pr_gate '{"state":"MERGED","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: draft pr" \
  "3|DRAFT|0|pull request is a draft" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":true,"mergeable":"MERGEABLE","labels":[],"files":[],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: conflicting mergeable" \
  "3|FIX_CONFLICTS|0|pull request has merge conflicts" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"CONFLICTING","labels":[],"files":[],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: unknown mergeable" \
  "2|WAIT_MERGEABLE|0|mergeability is still being computed" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"UNKNOWN","labels":[],"files":[],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: touches .github/workflows file" \
  "5|NEEDS_OWNER|0|pull request touches .github/workflows" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[{"path":".github/workflows/check.yml"}],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: touches .github/workflows subpath" \
  "5|NEEDS_OWNER|0|pull request touches .github/workflows" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[{"path":".github/workflows/ci/build.yml"}],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: carries no-review label" \
  "5|NEEDS_OWNER|0|pull request carries no-review label" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[{"name":"no-review"}],"files":[{"path":"README.md"}],"reviews":[]}' "settled_green" "clean" 0)"

check "decide_pr_gate: unreadable runs ci_state" \
  "1|ERROR|0|cannot read CI (runs)" \
  "$(run_decide_pr_gate "$BASE_PR" "unreadable:runs" "clean" 0)"

check "decide_pr_gate: unreadable status ci_state" \
  "1|ERROR|0|cannot read CI (status)" \
  "$(run_decide_pr_gate "$BASE_PR" "unreadable:status" "clean" 0)"

check "decide_pr_gate: pending ci_state" \
  "2|WAIT_CI|0|CI is still running on head" \
  "$(run_decide_pr_gate "$BASE_PR" "pending" "clean" 0)"

check "decide_pr_gate: failed ci_state single" \
  "3|FIX_CI|0|CI failed on head (check)" \
  "$(run_decide_pr_gate "$BASE_PR" "failed:check" "clean" 0)"

check "decide_pr_gate: failed ci_state multiple" \
  "3|FIX_CI|0|CI failed on head (test,lint)" \
  "$(run_decide_pr_gate "$BASE_PR" "failed:test,lint" "clean" 0)"

check "decide_pr_gate: wait_review review_state" \
  "2|WAIT_REVIEW|0|waiting for auto-review on current head" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "wait_review" 0)"

check "decide_pr_gate: findings review_state" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "findings" 0)"

check "decide_pr_gate: human review has CHANGES_REQUESTED" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[{"path":"README.md"}],"reviews":[{"state":"CHANGES_REQUESTED","author":{"login":"reviewer"}}]}' "settled_green" "clean" 0)"

check "decide_pr_gate: refused_size review_state" \
  "5|NEEDS_OWNER|0|auto-review refused diff size (**Not reviewed.**)" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "refused_size" 0)"

check "decide_pr_gate: skipped_low_risk review_state" \
  "4|NEEDS_META|0|auto-review skipped low-risk paths; meta must read diff" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "skipped_low_risk" 0)"

check "decide_pr_gate: settled_no_ci ci_state" \
  "4|NEEDS_META|0|no CI configured for commit; meta must verify diff" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_no_ci" "clean" 0)"

check "decide_pr_gate: cross_area is 1" \
  "4|NEEDS_META|0|cross-area pull request requires meta review" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "clean" 1)"

check "decide_pr_gate: all green and clean passed" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "clean" 0)"

check "decide_pr_gate: passed with not_required review" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "not_required" 0)"

# an earlier change combined Pure Core gate decision
cr_ci_green="$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$PR_CR_APP")"
check "decide_pr_gate an earlier change: changeset-release/master bot PR with settled_green -> 0|OK|1|gate passed" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$PR_CR_APP" "$cr_ci_green" "not_required" 0)"

cr_ci_no_verify="$(run_evaluate_ci_state "$RUNS_CR_ONLY_AR" "$EMPTY_STATUS" "$PR_CR_APP")"
check "decide_pr_gate an earlier change: changeset-release/master without Verify -> 3|FIX_CI" \
  "3|FIX_CI|0|CI failed on head (CI)" \
  "$(run_decide_pr_gate "$PR_CR_APP" "$cr_ci_no_verify" "not_required" 0)"

feat_pr="$(mk_ci_pr "feat/my-branch" "app/github-actions" "head384sha")"
feat_ci_ar="$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$feat_pr")"
check "decide_pr_gate an earlier change: feature branch with action_required -> 3|FIX_CI" \
  "3|FIX_CI|0|CI failed on head (CI)" \
  "$(run_decide_pr_gate "$feat_pr" "$feat_ci_ar" "not_required" 0)"

# Precedence tests
check "decide_pr_gate precedence: closed precedes draft" \
  "3|NOT_OPEN|0|pull request is not open" \
  "$(run_decide_pr_gate '{"state":"CLOSED","isDraft":true,"mergeable":"CONFLICTING","labels":[],"files":[],"reviews":[]}' "pending" "wait_review" 1)"

check "decide_pr_gate precedence: draft precedes conflicts" \
  "3|DRAFT|0|pull request is a draft" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":true,"mergeable":"CONFLICTING","labels":[],"files":[],"reviews":[]}' "pending" "wait_review" 1)"

check "decide_pr_gate precedence: conflicts precedes workflows" \
  "3|FIX_CONFLICTS|0|pull request has merge conflicts" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"CONFLICTING","labels":[{"name":"no-review"}],"files":[{"path":".github/workflows/ci.yml"}],"reviews":[]}' "pending" "wait_review" 1)"

check "decide_pr_gate precedence: workflows precedes no-review label" \
  "5|NEEDS_OWNER|0|pull request touches .github/workflows" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[{"name":"no-review"}],"files":[{"path":".github/workflows/ci.yml"}],"reviews":[]}' "pending" "wait_review" 1)"

check "decide_pr_gate precedence: no-review label precedes unreadable ci" \
  "5|NEEDS_OWNER|0|pull request carries no-review label" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[{"name":"no-review"}],"files":[{"path":"README.md"}],"reviews":[]}' "unreadable:runs" "wait_review" 1)"

check "decide_pr_gate precedence: unreadable ci precedes pending ci" \
  "1|ERROR|0|cannot read CI (runs)" \
  "$(run_decide_pr_gate "$BASE_PR" "unreadable:runs" "wait_review" 1)"

check "decide_pr_gate precedence: pending ci precedes failed ci" \
  "2|WAIT_CI|0|CI is still running on head" \
  "$(run_decide_pr_gate "$BASE_PR" "pending" "findings" 1)"

check "decide_pr_gate precedence: failed ci precedes wait review" \
  "3|FIX_CI|0|CI failed on head (check)" \
  "$(run_decide_pr_gate "$BASE_PR" "failed:check" "wait_review" 1)"

check "decide_pr_gate precedence: wait review precedes findings" \
  "2|WAIT_REVIEW|0|waiting for auto-review on current head" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[{"path":"src/app.sh"}],"reviews":[{"state":"CHANGES_REQUESTED"}]}' "settled_green" "wait_review" 1)"

check "decide_pr_gate precedence: human changes requested precedes refused size" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","labels":[],"files":[{"path":"src/app.sh"}],"reviews":[{"state":"CHANGES_REQUESTED"}]}' "settled_green" "refused_size" 1)"

check "decide_pr_gate precedence: refused size precedes cross area" \
  "5|NEEDS_OWNER|0|auto-review refused diff size (**Not reviewed.**)" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_green" "refused_size" 1)"

check "decide_pr_gate precedence: skipped low risk precedes settled no ci" \
  "4|NEEDS_META|0|auto-review skipped low-risk paths; meta must read diff" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_no_ci" "skipped_low_risk" 1)"

check "decide_pr_gate precedence: settled no ci precedes cross area" \
  "4|NEEDS_META|0|no CI configured for commit; meta must verify diff" \
  "$(run_decide_pr_gate "$BASE_PR" "settled_no_ci" "clean" 1)"

# Agent Executors block
mk_pr() { # $1 = author login (empty = no author field), $2 = body
  jq -nc --arg a "$1" --arg b "$2" \
    '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",labels:[],files:[{path:"src/app.sh"}],reviews:[]}
     + (if $a == "" then {} else {author:{login:$a}} end) + {body:$b}'
}
NOBLOCK_BODY="Closes #1"
BLOCK_BODY="Closes #1 <!-- EXECUTORS:START --> | x | <!-- EXECUTORS:END -->"
EXEC_WANT="4|NEEDS_META|0|agent pull request is missing required Executors ledger block"

check "decide_pr_gate: agent pr without executors block" \
  "$EXEC_WANT" \
  "$(run_decide_pr_gate "$(mk_pr acme-agent "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: project-agent pr without executors block" \
  "$EXEC_WANT" \
  "$(run_decide_pr_gate "$(mk_pr demo-app-agent "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: agent pr with executors block passes" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_pr acme-agent "$BLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: owner pr without executors block unchanged" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_pr hanzhad "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: dependabot pr without executors block unchanged" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_pr app/dependabot "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: pr without author field is not agent-opened" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_pr "" "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: agent pr skipped_low_risk reports executors first" \
  "$EXEC_WANT" \
  "$(run_decide_pr_gate "$(mk_pr acme-agent "$NOBLOCK_BODY")" "settled_green" "skipped_low_risk" 0)"

check "decide_pr_gate: agent pr with block and skipped_low_risk unchanged" \
  "4|NEEDS_META|0|auto-review skipped low-risk paths; meta must read diff" \
  "$(run_decide_pr_gate "$(mk_pr acme-agent "$BLOCK_BODY")" "settled_green" "skipped_low_risk" 0)"

check "decide_pr_gate: app/ prefix and [bot] suffix are stripped" \
  "$EXEC_WANT" \
  "$(run_decide_pr_gate "$(mk_pr "app/acme-agent[bot]" "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: [bot] suffix alone is stripped" \
  "$EXEC_WANT" \
  "$(run_decide_pr_gate "$(mk_pr "acme-agent[bot]" "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: unlisted app login is not agent-opened by default" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_pr acme-org-app "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: PR_GATE_AGENT_AUTHOR_RE adds an app login" \
  "$EXEC_WANT" \
  "$(PR_GATE_AGENT_AUTHOR_RE='^(acme-org-app|[A-Za-z0-9-]+-agent)$' \
     run_decide_pr_gate "$(mk_pr "app/acme-org-app[bot]" "$NOBLOCK_BODY")" "settled_green" "clean" 0)"

check "decide_pr_gate: NEEDS_OWNER refused_size wins over missing executors block" \
  "5|NEEDS_OWNER|0|auto-review refused diff size (**Not reviewed.**)" \
  "$(run_decide_pr_gate "$(mk_pr acme-agent "$NOBLOCK_BODY")" "settled_green" "refused_size" 0)"

check "decide_pr_gate: NEEDS_OWNER workflows wins over missing executors block" \
  "5|NEEDS_OWNER|0|pull request touches .github/workflows" \
  "$(run_decide_pr_gate "$(mk_pr acme-agent "$NOBLOCK_BODY" | jq -c '.files=[{path:".github/workflows/x.yml"}]')" "settled_green" "clean" 0)"


# ═════════════════════════════════════════════════════════════════════════════
# 5. touches_protected <files_or_pr_json> <codeowners_text>
# ═════════════════════════════════════════════════════════════════════════════

CO_SAMPLE='/install.sh @hanzhad
/bin/pr-gate.sh @hanzhad
/agents/hooks/ @hanzhad
/.github/ @hanzhad
/claude/settings.*.json @hanzhad
/*/harness.conf @hanzhad'

check "touches_protected: directory prefix rule with PR JSON" \
  "$(printf 'agents/hooks/manifest.json\nagents/hooks/deny-live-config-write.sh')" \
  "$(run_touches_protected '{"files":[{"path":"agents/hooks/manifest.json"},{"path":"agents/hooks/deny-live-config-write.sh"},{"path":"docs/agents/hooks/x"},{"path":"agents/hooks-extra/x"}]}' "$CO_SAMPLE")"

check "touches_protected: directory prefix rule with newline paths" \
  "$(printf 'agents/hooks/manifest.json\nagents/hooks/deny-live-config-write.sh')" \
  "$(run_touches_protected "$(printf 'agents/hooks/manifest.json\nagents/hooks/deny-live-config-write.sh\ndocs/agents/hooks/x\nagents/hooks-extra/x')" "$CO_SAMPLE")"

check "touches_protected: exact path and .github directory rules" \
  "$(printf 'install.sh\nbin/pr-gate.sh\n.github/CODEOWNERS\n.github/workflows/check.yml')" \
  "$(run_touches_protected "$(printf 'install.sh\ndocs/install.sh\nbin/pr-gate.sh\nfoo/bin/pr-gate.sh\n.github/CODEOWNERS\n.github/workflows/check.yml')" "$CO_SAMPLE")"

check "touches_protected: wildcard /claude/settings.*.json" \
  "claude/settings.local.json" \
  "$(run_touches_protected "$(printf 'claude/settings.local.json\nclaude/settings.json\nclaude/settings/sub.json')" "$CO_SAMPLE")"

check "touches_protected: wildcard /*/harness.conf" \
  "$(printf 'claude/harness.conf\nantigravity/harness.conf')" \
  "$(run_touches_protected "$(printf 'claude/harness.conf\nantigravity/harness.conf\na/b/harness.conf')" "$CO_SAMPLE")"

CO_CRLF=$(printf '# leading comment\r\n\r\n  /install.sh   @hanzhad  \r\n# /the design docs.md @hanzhad\r\n')
check "touches_protected: ignores comments, blanks, spaces, and CRLF" \
  "install.sh" \
  "$(run_touches_protected "$(printf 'install.sh\ndocs/0030.md')" "$CO_CRLF")"

check "touches_protected: non-protected paths return empty" \
  "" \
  "$(run_touches_protected "$(printf 'the design docs.md\ntests/test-pr-gate.sh')" "$CO_SAMPLE")"

if [ -f "$here/.github/CODEOWNERS" ]; then
  pass "CODEOWNERS: .github/CODEOWNERS exists"
  co_real=$(cat "$here/.github/CODEOWNERS")
  required_protected=$(printf '%s\n' \
    "bin/pr-gate.sh" \
    "lib/pr-gate-core.sh" \
    "lib/pr_gate_watch_core.py" \
    "lib/auto-review-mark.sh" \
    ".github/CODEOWNERS" \
    ".github/workflows/ci.yml")
  check "CODEOWNERS: real .github/CODEOWNERS matches all protected paths" \
    "$required_protected" \
    "$(run_touches_protected "$required_protected" "$co_real")"
  check "CODEOWNERS: real .github/CODEOWNERS ignores normal paths" \
    "" \
    "$(run_touches_protected "$(printf 'the design docs.md\ntests/test-pr-gate.sh')" "$co_real")"
else
  fail_case "CODEOWNERS: .github/CODEOWNERS exists" "file present" "missing"
  fail_case "CODEOWNERS: real .github/CODEOWNERS matches all protected paths" "all protected paths" ".github/CODEOWNERS missing"
  fail_case "CODEOWNERS: real .github/CODEOWNERS ignores normal paths" "empty" ".github/CODEOWNERS missing"
fi

# Fail-closed CODEOWNERS and truncated/missing files
check "touches_protected: empty codeowners_text -> <unreadable:codeowners>" \
  "<unreadable:codeowners>" \
  "$(run_touches_protected "install.sh" "")"

check "touches_protected: comment/blank-only codeowners_text -> <unreadable:codeowners>" \
  "<unreadable:codeowners>" \
  "$(run_touches_protected "install.sh" "$(printf '# just a comment\n\n')")"

check "touches_protected: empty files input -> <unreadable:files>" \
  "<unreadable:files>" \
  "$(run_touches_protected "" "$CO_SAMPLE")"

check "touches_protected: JSON missing .files -> <unreadable:files>" \
  "<unreadable:files>" \
  "$(run_touches_protected '{"state":"OPEN"}' "$CO_SAMPLE")"

check "touches_protected: JSON with empty .files -> <unreadable:files>" \
  "<unreadable:files>" \
  "$(run_touches_protected '{"state":"OPEN","files":[]}' "$CO_SAMPLE")"

TRUNC_FILES_JSON=$(jq -nc '{files:[range(1;101) | {path:("src/f" + (tostring) + ".sh")}]}')
check "touches_protected: 100 files -> <unreadable:files-truncated>" \
  "<unreadable:files-truncated>" \
  "$(run_touches_protected "$TRUNC_FILES_JSON" "$CO_SAMPLE")"


# ═════════════════════════════════════════════════════════════════════════════
# 6. decide_pr_gate protected_hits, owner approval release, fail-closed
# ═════════════════════════════════════════════════════════════════════════════

mk_owner_pr() { # $1 = headRefOid, $2 = files_json, $3 = reviews_json
  jq -nc --arg oid "$1" --argjson files "$2" --argjson reviews "$3" \
    '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",headRefOid:$oid,labels:[],files:$files,reviews:$reviews}'
}

BASE_FILES='[{"path":"README.md"}]'
WF_FILES='[{"path":".github/workflows/check.yml"}]'

check "decide_pr_gate: protected hit without owner approval" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (agents/hooks/manifest.json)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]')" "settled_green" "clean" 0 "agents/hooks/manifest.json")"

check "decide_pr_gate: multiple protected hits formatted as CSV" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh,agents/hooks/manifest.json)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]')" "settled_green" "clean" 0 "$(printf 'install.sh\nagents/hooks/manifest.json')")"

check "decide_pr_gate precedence: conflict precedes protected_hits" \
  "3|FIX_CONFLICTS|0|pull request has merge conflicts" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]' | jq -c '.mergeable="CONFLICTING"')" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate precedence: workflows precedes protected_hits" \
  "5|NEEDS_OWNER|0|pull request touches .github/workflows" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$WF_FILES" '[]')" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate precedence: protected_hits precedes no-review label" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]' | jq -c '.labels=[{name:"no-review"}]')" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate precedence: protected_hits precedes WAIT_CI" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]')" "pending" "clean" 0 "install.sh")"

check "decide_pr_gate precedence: protected_hits precedes unreadable CI" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]')" "unreadable:runs" "clean" 0 "install.sh")"

GQL_OK='[{"author":{"login":"hanzhad"},"state":"APPROVED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval (GraphQL): releases protected_hits -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_OK")" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate owner approval (GraphQL): released protected_hits still checks CI pending" \
  "2|WAIT_CI|0|CI is still running on head" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_OK")" "pending" "clean" 0 "install.sh")"

check "decide_pr_gate owner approval (GraphQL): releases workflows -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$WF_FILES" "$GQL_OK")" "settled_green" "clean" 0)"

check "decide_pr_gate owner approval (GraphQL): releases refused_size -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_OK")" "settled_green" "refused_size" 0)"

REST_OK='[{"user":{"login":"hanzhad"},"state":"APPROVED","commit_id":"head123"}]'
check "decide_pr_gate owner approval (REST): releases protected_hits -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$REST_OK")" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate owner approval (REST): releases workflows -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$WF_FILES" "$REST_OK")" "settled_green" "clean" 0)"

check "decide_pr_gate owner approval (REST): releases refused_size -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$REST_OK")" "settled_green" "refused_size" 0)"

GQL_APP_THEN_COMMENT='[{"author":{"login":"hanzhad"},"state":"APPROVED","commit":{"oid":"head123"}},{"author":{"login":"hanzhad"},"state":"COMMENTED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval: APPROVED followed by COMMENTED still releases" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_APP_THEN_COMMENT")" "settled_green" "clean" 0 "install.sh")"

GQL_STALE='[{"author":{"login":"hanzhad"},"state":"APPROVED","commit":{"oid":"old456"}}]'
check "decide_pr_gate owner approval: stale commit does not release protected_hits" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_STALE")" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate owner approval: stale commit does not release workflows" \
  "5|NEEDS_OWNER|0|pull request touches .github/workflows" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$WF_FILES" "$GQL_STALE")" "settled_green" "clean" 0)"

GQL_COMMENT='[{"author":{"login":"hanzhad"},"state":"COMMENTED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval: owner COMMENTED does not release protected_hits" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_COMMENT")" "settled_green" "clean" 0 "install.sh")"

GQL_CR='[{"author":{"login":"hanzhad"},"state":"CHANGES_REQUESTED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval: owner CHANGES_REQUESTED does not release protected_hits" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_CR")" "settled_green" "clean" 0 "install.sh")"

GQL_APP_THEN_CR='[{"author":{"login":"hanzhad"},"state":"APPROVED","commit":{"oid":"head123"}},{"author":{"login":"hanzhad"},"state":"CHANGES_REQUESTED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval: APPROVED overridden by later CHANGES_REQUESTED" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_APP_THEN_CR")" "settled_green" "clean" 0 "install.sh")"

GQL_OTHER='[{"author":{"login":"reviewer"},"state":"APPROVED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval: non-owner APPROVED does not release protected_hits" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_OTHER")" "settled_green" "clean" 0 "install.sh")"

check "decide_pr_gate owner approval: PR_GATE_OWNER_LOGIN rejects default owner" \
  "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" \
  "$(PR_GATE_OWNER_LOGIN=alice run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_OK")" "settled_green" "clean" 0 "install.sh")"

GQL_ALICE='[{"author":{"login":"alice"},"state":"APPROVED","commit":{"oid":"head123"}}]'
check "decide_pr_gate owner approval: PR_GATE_OWNER_LOGIN accepts configured owner" \
  "0|OK|1|gate passed" \
  "$(PR_GATE_OWNER_LOGIN=alice run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_ALICE")" "settled_green" "clean" 0 "install.sh")"

TRUNC_PR_JSON=$(jq -nc '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",headRefOid:"head123",labels:[],files:[range(1;101)|{path:("src/f"+tostring+".sh")}],reviews:[]}')
check "decide_pr_gate: 100-file truncation without owner approval -> NEEDS_OWNER" \
  "5|NEEDS_OWNER|0|pull request file list is truncated (>=100 files)" \
  "$(run_decide_pr_gate "$TRUNC_PR_JSON" "settled_green" "clean" 0)"

TRUNC_PR_APPROVED=$(printf '%s' "$TRUNC_PR_JSON" | jq -c --argjson r "$GQL_OK" '.reviews = $r')
check "decide_pr_gate: 100-file truncation with owner approval -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$TRUNC_PR_APPROVED" "settled_green" "clean" 0)"

check "decide_pr_gate: <unreadable:codeowners> without owner approval -> NEEDS_OWNER" \
  "5|NEEDS_OWNER|0|cannot read .github/CODEOWNERS" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]')" "settled_green" "clean" 0 "<unreadable:codeowners>")"

check "decide_pr_gate: <unreadable:codeowners> with owner approval -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" "$GQL_OK")" "settled_green" "clean" 0 "<unreadable:codeowners>")"

check "decide_pr_gate: <unreadable:files> -> NEEDS_OWNER" \
  "5|NEEDS_OWNER|0|cannot read pull request changed files" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 "$BASE_FILES" '[]')" "settled_green" "clean" 0 "<unreadable:files>")"

check "decide_pr_gate: OPEN+MERGEABLE PR with empty .files -> NEEDS_OWNER" \
  "5|NEEDS_OWNER|0|cannot read pull request changed files" \
  "$(run_decide_pr_gate "$(mk_owner_pr head123 '[]' '[]')" "settled_green" "clean" 0)"


# ═════════════════════════════════════════════════════════════════════════════
# 7. count_auto_review_finding_rounds & finding-round circuit breaker
# ═════════════════════════════════════════════════════════════════════════════

check "count_auto_review_finding_rounds: empty string -> 0" \
  "0" \
  "$(run_count_auto_review_finding_rounds "")"

check "count_auto_review_finding_rounds: empty array -> 0" \
  "0" \
  "$(run_count_auto_review_finding_rounds '[]')"

REVIEWS_NON_FINDINGS='[
  {"commit_id":"c111111","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"c222222","body":"\n\n**No findings.** — empty diff\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"c333333","body":"**Skipped — generated files only.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"c444444","body":"**Skipped — low-risk paths only.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"c555555","body":"**Not reviewed.** — diff too large\n\n---\n_Automated review. Not an approval._"}
]'
check "count_auto_review_finding_rounds: clean/skipped/not-reviewed only -> 0" \
  "0" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_NON_FINDINGS")"

REVIEWS_SAME_SHA_PLUS_HUMAN='[
  {"commit_id":"aaaa111","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"aaaa111","body":"**2 findings.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"bbbb222","body":"**1 finding.** Please fix."}
]'
check "count_auto_review_finding_rounds: 2 findings on same SHA + human review -> 1" \
  "1" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_SAME_SHA_PLUS_HUMAN")"

REVIEWS_TWO_SHAS='[
  {"commit_id":"aaaa111","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"bbbb222","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"cccc333","body":"**2 findings.**\n\n---\n_Automated review. Not an approval._"}
]'
check "count_auto_review_finding_rounds: 2 distinct finding SHAs (+1 clean SHA) -> 2" \
  "2" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_TWO_SHAS")"

REVIEWS_MIXED_THREE='[
  {"commit_id":"1111aaa000000000000000000000000000000000","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},
  {"commit":{"oid":"2222bbb000000000000000000000000000000000"},"body":"Please update tests.\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":null,"body":"**1 finding.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"3333ccc000000000000000000000000000000000\",\"verdict\":\"findings\",\"findings\":1} -->"}
]'
check "count_auto_review_finding_rounds: 3 distinct SHAs with mixed commit_id/commit.oid/embedded sha -> 3" \
  "3" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_MIXED_THREE")"

REVIEWS_COMMIT_FOOTER='[
  {"commit_id":null,"body":"**1 finding.**\n\n---\n_Automated review. Not an approval._ • Commit: 1111aaa"},
  {"commit_id":null,"body":"**1 finding.**\n\n---\n_Automated review. Not an approval._ • Commit: 2222bbb"},
  {"commit_id":null,"body":"**1 finding.**\n\n---\n_Automated review. Not an approval._ • Commit: 3333ccc"}
]'
check "count_auto_review_finding_rounds: 3 distinct SHAs via Commit footer fallback -> 3" \
  "3" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_COMMIT_FOOTER")"

REVIEWS_NORM_SHA='[
  {"commit":{"oid":"abcdef1234567890abcdef1234567890abcdef12"},"body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"abcdef1","body":"**2 findings.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":null,"body":"**1 finding.**\n\n<!-- auto-review: {\"v\":1,\"tool\":\"auto-review\",\"sha\":\"abcdef1\",\"verdict\":\"findings\",\"findings\":1} -->"},
  {"commit_id":null,"body":"**1 finding.**\n\n---\n_Automated review. Not an approval._ • Commit: abcdef1"}
]'
check "count_auto_review_finding_rounds: 7-char vs 40-char SHA normalization -> 1" \
  "1" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_NORM_SHA")"

REVIEWS_SIX_PREFIX='[
  {"commit_id":"abcdef1234567890abcdef1234567890abcdef12","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},
  {"commit_id":"abcdef2234567890abcdef1234567890abcdef12","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"}
]'
check "count_auto_review_finding_rounds: distinct 7-char prefixes sharing 6 chars -> 2" \
  "2" \
  "$(run_count_auto_review_finding_rounds "$REVIEWS_SIX_PREFIX")"

mk_finding_rounds_pr() { # $1 = rounds count, $2 = owner_approved (0|1)
  local n="$1"
  local approved="${2:-0}"
  jq -nc --argjson n "$n" --argjson approved "$approved" '
    ([range(1; $n + 1) | {
      author: {login: "auto-review"},
      state: "COMMENTED",
      commit: {oid: ("sha000" + tostring + "000000000000000000000000000000000")},
      body: "**1 finding.**\n\n---\n_Automated review. Not an approval._"
    }] + (if $approved == 1 then [{author:{login:"hanzhad"},state:"APPROVED",commit:{oid:"head123"}}] else [] end)) as $revs |
    {
      state:"OPEN",isDraft:false,mergeable:"MERGEABLE",headRefOid:"head123",
      labels:[],files:[{path:"src/app.sh"}],reviews:$revs
    }'
}

check "decide_pr_gate circuit breaker: 0 rounds -> FIX_FINDINGS" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 0 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: 1 round -> FIX_FINDINGS" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 1 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: 2 rounds -> FIX_FINDINGS" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 2 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: 3 rounds -> NEEDS_META" \
  "4|NEEDS_META|0|auto-review findings persisted across 3 commits; stop patching and escalate to meta" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 3 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: 4 rounds -> NEEDS_META" \
  "4|NEEDS_META|0|auto-review findings persisted across 4 commits; stop patching and escalate to meta" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 4 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: owner_approved=1 overrides 3 rounds -> FIX_FINDINGS" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 3 1)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: PR_GATE_MAX_FINDING_ROUNDS=2 with 2 rounds -> NEEDS_META" \
  "4|NEEDS_META|0|auto-review findings persisted across 2 commits; stop patching and escalate to meta" \
  "$(PR_GATE_MAX_FINDING_ROUNDS=2 run_decide_pr_gate "$(mk_finding_rounds_pr 2 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: PR_GATE_MAX_FINDING_ROUNDS=2 with 1 round -> FIX_FINDINGS" \
  "3|FIX_FINDINGS|0|review findings open on current head" \
  "$(PR_GATE_MAX_FINDING_ROUNDS=2 run_decide_pr_gate "$(mk_finding_rounds_pr 1 0)" "settled_green" "findings" 0)"

check "decide_pr_gate circuit breaker: 3 historical finding rounds with clean head -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_finding_rounds_pr 3 0)" "settled_green" "clean" 0)"


# ═════════════════════════════════════════════════════════════════════════════
# 8. extract_hotfix_debt_issue & decide_pr_gate hotfix debt lock
# ═════════════════════════════════════════════════════════════════════════════

check_debt_extract() { # $1 = name, $2 = want_rc, $3 = want_out, $4 = body
  local got_out got_rc=0
  got_out=$(run_extract_hotfix_debt_issue "$4") || got_rc=$?
  check "$1 (rc)" "$2" "$got_rc"
  check "$1 (out)" "$3" "$got_out"
}

check_debt_extract "extract_hotfix_debt_issue: #41 in CRLF body" \
  "0" "#41" "$(printf 'Urgent hotfix.\r\n\r\nDebt-Issue: #41\r\nDetails\r\n')"

check_debt_extract "extract_hotfix_debt_issue: owner/repo#41" \
  "0" "acme/webapp#41" "$(printf 'Urgent hotfix.\nDebt-Issue: acme/webapp#41\n')"

check_debt_extract "extract_hotfix_debt_issue: multiple lines takes first" \
  "0" "#11" "$(printf 'Debt-Issue: #11\nDebt-Issue: #22\n')"

check_debt_extract "extract_hotfix_debt_issue: empty body" \
  "1" "" ""

check_debt_extract "extract_hotfix_debt_issue: body without Debt-Issue line" \
  "1" "" "$(printf 'Closes #41\nFixes #99\n')"

check_debt_extract "extract_hotfix_debt_issue: invalid TBD" \
  "1" "" "$(printf 'Debt-Issue: TBD\n')"

check_debt_extract "extract_hotfix_debt_issue: invalid #abc" \
  "1" "" "$(printf 'Debt-Issue: #abc\n')"

check_debt_extract "extract_hotfix_debt_issue: invalid missing hash 41" \
  "1" "" "$(printf 'Debt-Issue: 412\n')"

mk_hotfix_pr() { # $1 = labels_json, $2 = body, $3 = reviews_json, $4 = debt_issue_state (optional)
  if [ -n "${4:-}" ]; then
    jq -nc --argjson labels "$1" --arg body "$2" --argjson reviews "$3" --arg dis "$4" \
      '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",headRefOid:"head123",labels:$labels,files:[{path:"src/app.sh"}],reviews:$reviews,body:$body,debt_issue_state:$dis}'
  else
    jq -nc --argjson labels "$1" --arg body "$2" --argjson reviews "$3" \
      '{state:"OPEN",isDraft:false,mergeable:"MERGEABLE",headRefOid:"head123",labels:$labels,files:[{path:"src/app.sh"}],reviews:$reviews,body:$body}'
  fi
}

check "decide_pr_gate hotfix: missing Debt-Issue -> NEEDS_META" \
  "4|NEEDS_META|0|hotfix pull request requires open Debt-Issue: #<N> in body" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Emergency patch' '[]')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: case-insensitive HOTFIX label missing Debt-Issue -> NEEDS_META" \
  "4|NEEDS_META|0|hotfix pull request requires open Debt-Issue: #<N> in body" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"HOTFIX"}]' 'Emergency patch' '[]')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: invalid Debt-Issue TBD -> NEEDS_META" \
  "4|NEEDS_META|0|hotfix pull request requires open Debt-Issue: #<N> in body" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Debt-Issue: TBD' '[]')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: debt_issue_state CLOSED -> NEEDS_META" \
  "4|NEEDS_META|0|hotfix Debt-Issue (#77) is not open (CLOSED)" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Debt-Issue: #77' '[]' 'CLOSED')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: cross-repo debt_issue_state UNREADABLE -> NEEDS_META" \
  "4|NEEDS_META|0|hotfix Debt-Issue (acme/webapp#77) is not open (UNREADABLE)" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Debt-Issue: acme/webapp#77' '[]' 'UNREADABLE')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: debt_issue_state OPEN -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Debt-Issue: #77' '[]' 'OPEN')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: valid Debt-Issue without debt_issue_state -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Debt-Issue: #77' '[]')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: owner_approved=1 without Debt-Issue -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Emergency patch' "$GQL_OK")" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: owner_approved=1 with CLOSED Debt-Issue -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"hotfix"}]' 'Debt-Issue: #77' "$GQL_OK" 'CLOSED')" "settled_green" "clean" 0)"

check "decide_pr_gate hotfix: non-hotfix label without Debt-Issue -> OK" \
  "0|OK|1|gate passed" \
  "$(run_decide_pr_gate "$(mk_hotfix_pr '[{"name":"bug"},{"name":"hotfix-candidate"}]' 'Normal fix' '[]')" "settled_green" "clean" 0)"


# ═════════════════════════════════════════════════════════════════════════════
# 8b. Extracted Pure Core Helpers: debt ref parsing, ledger, merge fallback, aliases
# ═════════════════════════════════════════════════════════════════════════════

if declare -F parse_hotfix_debt_issue_ref >/dev/null 2>&1; then
  got_ref="$(parse_hotfix_debt_issue_ref "#41" "acme/webapp")"
  check "parse_hotfix_debt_issue_ref: local #41" "$(printf 'acme/webapp\t41')" "$got_ref"
  got_ref="$(parse_hotfix_debt_issue_ref "org/repo#99" "acme/webapp")"
  check "parse_hotfix_debt_issue_ref: cross-repo org/repo#99" "$(printf 'org/repo\t99')" "$got_ref"
  rc=0; parse_hotfix_debt_issue_ref "TBD" "acme/webapp" >/dev/null 2>&1 || rc=$?
  check_rc "parse_hotfix_debt_issue_ref: invalid TBD returns 1" "1" "$rc"
  rc=0; parse_hotfix_debt_issue_ref "#12" "" >/dev/null 2>&1 || rc=$?
  check_rc "parse_hotfix_debt_issue_ref: empty default_repo returns 1" "1" "$rc"
fi

if declare -F evaluate_executor_ledger >/dev/null 2>&1; then
  rc=0; got="$(evaluate_executor_ledger "$(mk_pr acme-agent "$NOBLOCK_BODY")")" || rc=$?
  check_rc "evaluate_executor_ledger: agent without block rc=1" "1" "$rc"
  check "evaluate_executor_ledger: agent without block -> missing" "missing" "$got"
  rc=0; got="$(evaluate_executor_ledger "$(mk_pr acme-agent "$BLOCK_BODY")")" || rc=$?
  check_rc "evaluate_executor_ledger: agent with block rc=0" "0" "$rc"
  check "evaluate_executor_ledger: agent with block -> ok" "ok" "$got"
  rc=0; got="$(evaluate_executor_ledger "$(mk_pr hanzhad "$NOBLOCK_BODY")")" || rc=$?
  check_rc "evaluate_executor_ledger: owner without block rc=0" "0" "$rc"
  check "evaluate_executor_ledger: owner without block -> ok" "ok" "$got"
  rc=0; got="$(evaluate_executor_ledger "true" "false")" || rc=$?
  check_rc "evaluate_executor_ledger: 2-arg true/false rc=1" "1" "$rc"
  check "evaluate_executor_ledger: 2-arg true/false -> missing" "missing" "$got"
fi

if declare -F evaluate_merge_fallback >/dev/null 2>&1; then
  check "evaluate_merge_fallback: CONFLICTING -> 3|FIX_CONFLICTS" \
    "3|FIX_CONFLICTS|0|pull request has merge conflicts" \
    "$(evaluate_merge_fallback "head123" '{"mergeable":"CONFLICTING","headRefOid":"head123"}')"
  check "evaluate_merge_fallback: head changed -> 1|ERROR" \
    "1|ERROR|0|pull request head changed during merge (head123 -> new456)" \
    "$(evaluate_merge_fallback "head123" '{"mergeable":"MERGEABLE","headRefOid":"new456"}')"
  check "evaluate_merge_fallback: UNKNOWN -> 2|WAIT_MERGEABLE" \
    "2|WAIT_MERGEABLE|0|mergeability is still being computed" \
    "$(evaluate_merge_fallback "head123" '{"mergeable":"UNKNOWN","headRefOid":"head123"}')"
  check "evaluate_merge_fallback: empty recheck -> 1|ERROR" \
    "1|ERROR|0|cannot verify mergeable state before admin fallback (empty)" \
    "$(evaluate_merge_fallback "head123" "")"
  check "evaluate_merge_fallback: MERGEABLE same head -> 0|ADMIN_MERGE" \
    "0|ADMIN_MERGE|1|mergeable re-verified on head" \
    "$(evaluate_merge_fallback "head123" '{"mergeable":"MERGEABLE","headRefOid":"head123"}')"
fi

if declare -F count_finding_rounds >/dev/null 2>&1; then
  check "count_finding_rounds alias matches count_auto_review_finding_rounds" \
    "2" "$(count_finding_rounds "$REVIEWS_TWO_SHAS")"
fi

if declare -F auto_review_first_line >/dev/null 2>&1; then
  check "auto_review_first_line strips leading CRLF blank lines" \
    "**No findings.**" "$(auto_review_first_line "$(printf '\r\n\r\n**No findings.**\r\nsecond')")"
fi

if declare -F last_auto_review_commit_sha >/dev/null 2>&1; then
  check "last_auto_review_commit_sha extracts latest automated review sha" \
    "head123" "$(last_auto_review_commit_sha '[{"commit_id":"older111","body":"**1 finding.**\n\n---\n_Automated review. Not an approval._"},{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._"},{"commit_id":"other999","body":"LGTM"}]')"
fi


# ═════════════════════════════════════════════════════════════════════════════
# 9. Part 2: >2.5 MB JSON payloads in memory (zero ARG_MAX blowup)
# ═════════════════════════════════════════════════════════════════════════════

MIN_LARGE_BYTES=2621440

big_runs_ok="$(python3 -c '
import json
runs = [{"name": f"check-{i}", "status": "completed", "conclusion": "success", "display_title": "x" * 20000} for i in range(136)]
print(json.dumps({"total_count": len(runs), "workflow_runs": runs}, separators=(",", ":")))
')"
check "an earlier change fixture: big_runs_ok exceeds 2.5 MiB" "1" "$([ "${#big_runs_ok}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

big_runs_fail="$(python3 -c '
import json
runs = [{"name": f"check-{i}", "status": "completed", "conclusion": "success", "display_title": "x" * 20000} for i in range(136)]
runs.append({"name": "late-fail", "status": "completed", "conclusion": "failure"})
print(json.dumps({"total_count": len(runs), "workflow_runs": runs}, separators=(",", ":")))
')"
check "an earlier change fixture: big_runs_fail exceeds 2.5 MiB" "1" "$([ "${#big_runs_fail}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

big_status_ok="$(python3 -c '
import json
sts = [{"context": f"ctx-{i}", "state": "success", "description": "y" * 20000} for i in range(136)]
print(json.dumps({"state": "success", "total_count": len(sts), "statuses": sts}, separators=(",", ":")))
')"
check "an earlier change fixture: big_status_ok exceeds 2.5 MiB" "1" "$([ "${#big_status_ok}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

big_reviews_clean="$(python3 -c '
import json
revs = [{"commit_id": f"old{i:04d}", "body": "comment " + ("z" * 40000)} for i in range(68)]
revs.append({"commit_id": "head123", "body": "**No findings.**\n\n" + ("details " * 1000) + "\n---\n_Automated review. Not an approval._"})
print(json.dumps(revs, separators=(",", ":")))
')"
check "an earlier change fixture: big_reviews_clean exceeds 2.5 MiB" "1" "$([ "${#big_reviews_clean}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

big_single_review="$(python3 -c '
import json
revs = [{"commit_id": "head123", "body": "**No findings.**\n\n" + ("x" * 2700000) + "\n\n---\n_Automated review. Not an approval._"}]
print(json.dumps(revs, separators=(",", ":")))
')"
check "an earlier change fixture: big_single_review exceeds 2.5 MiB" "1" "$([ "${#big_single_review}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

big_pr_protected="$(python3 -c '
import json
files = [{"path": f"src/dir{i}/file_{i}.sh"} for i in range(250)]
files.append({"path": "install.sh"})
print(json.dumps({
  "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
  "headRefOid": "head123", "headRefName": "feat/large",
  "author": {"login": "hanzhad"},
  "labels": [], "files": files, "files_complete": True, "changedFiles": len(files),
  "reviews": [],
  "body": "Large PR\n\n" + ("B" * 2700000)
}, separators=(",", ":")))
')"
check "an earlier change fixture: big_pr_protected exceeds 2.5 MiB" "1" "$([ "${#big_pr_protected}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

big_pr_clean="$(python3 -c '
import json
files = [{"path": f"src/dir{i}/file_{i}.sh"} for i in range(250)]
revs = [{"author": {"login": "auto-review"}, "state": "COMMENTED", "commit_id": "head384sha",
         "body": "**No findings.**\n\n" + ("R" * 1400000) + "\n---\n_Automated review. Not an approval._"}]
print(json.dumps({
  "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
  "headRefOid": "head384sha", "headRefName": "changeset-release/master",
  "author": {"login": "app/github-actions"},
  "labels": [], "files": files, "files_complete": True, "changedFiles": len(files),
  "reviews": revs,
  "body": "Large release PR\n\n" + ("B" * 1400000)
}, separators=(",", ":")))
')"
check "an earlier change fixture: big_pr_clean exceeds 2.5 MiB" "1" "$([ "${#big_pr_clean}" -gt "$MIN_LARGE_BYTES" ] && echo 1 || echo 0)"

rc=0; got="$(run_evaluate_ci_state "$big_runs_ok" '{"state":"success","total_count":0,"statuses":[]}' 2>&1)" || rc=$?
check_rc "evaluate_ci_state an earlier change (>2.5MB runs_json rc)" "0" "$rc"
check "evaluate_ci_state an earlier change (>2.5MB runs_json -> settled_green)" "settled_green" "$got"

rc=0; got="$(run_evaluate_ci_state "$big_runs_fail" '{"state":"success","total_count":0,"statuses":[]}' 2>&1)" || rc=$?
check_rc "evaluate_ci_state an earlier change (>2.5MB failing runs_json rc)" "0" "$rc"
check "evaluate_ci_state an earlier change (>2.5MB failing runs_json -> failed:late-fail)" "failed:late-fail" "$got"

rc=0; got="$(run_evaluate_ci_state '{"total_count":0,"workflow_runs":[]}' "$big_status_ok" 2>&1)" || rc=$?
check_rc "evaluate_ci_state an earlier change (>2.5MB status_json rc)" "0" "$rc"
check "evaluate_ci_state an earlier change (>2.5MB status_json -> settled_green)" "settled_green" "$got"

rc=0; got="$(run_evaluate_ci_state "$big_runs_ok" "$big_status_ok" 2>&1)" || rc=$?
check_rc "evaluate_ci_state an earlier change (>2.5MB runs + >2.5MB status rc)" "0" "$rc"
check "evaluate_ci_state an earlier change (>2.5MB runs + >2.5MB status -> settled_green)" "settled_green" "$got"

rc=0; got="$(run_evaluate_ci_state "$RUNS_CR_REL_VERIFY" "$EMPTY_STATUS" "$big_pr_clean" 2>&1)" || rc=$?
check_rc "evaluate_ci_state an earlier change (>2.5MB pr_json + an earlier change rc)" "0" "$rc"
check "evaluate_ci_state an earlier change (>2.5MB pr_json + an earlier change -> settled_green)" "settled_green" "$got"

rc=0; got="$(run_evaluate_review_state 1 "head123" "$big_reviews_clean" 0 2>&1)" || rc=$?
check_rc "evaluate_review_state an earlier change (>2.5MB reviews array rc)" "0" "$rc"
check "evaluate_review_state an earlier change (>2.5MB reviews array -> clean)" "clean" "$got"

rc=0; got="$(run_evaluate_review_state 1 "head123" "$big_single_review" 0 2>&1)" || rc=$?
check_rc "evaluate_review_state an earlier change (>2.5MB single review body rc)" "0" "$rc"
check "evaluate_review_state an earlier change (>2.5MB single review body -> clean)" "clean" "$got"

rc=0; got="$(run_filter_auto_reviews "$big_reviews_clean" "head123" 2>&1)" || rc=$?
check_rc "filter_auto_reviews an earlier change (>2.5MB reviews_json rc)" "0" "$rc"
check "filter_auto_reviews an earlier change (>2.5MB reviews_json -> verdict clean)" "clean" "$(run_auto_review_verdict "$(printf '%s' "$got" | jq -r '.body // ""' 2>/dev/null || echo "")")"

big_reviews_findings="$(python3 -c '
import json
revs = [{"commit_id": f"old{i:04d}", "body": "**No findings.**\n\n" + ("z" * 40000) + "\n---\n_Automated review. Not an approval._"} for i in range(68)]
revs.append({"commit_id": "aaaa111", "body": "**1 finding.**\n\n---\n_Automated review. Not an approval._"})
revs.append({"commit_id": "bbbb222", "body": "**2 findings.**\n\n---\n_Automated review. Not an approval._"})
print(json.dumps(revs, separators=(",", ":")))
')"
rc=0; got="$(run_count_auto_review_finding_rounds "$big_reviews_findings" 2>&1)" || rc=$?
check_rc "count_auto_review_finding_rounds an earlier change (>2.5MB reviews_json rc)" "0" "$rc"
check "count_auto_review_finding_rounds an earlier change (>2.5MB reviews_json -> 2)" "2" "$got"

rc=0; got="$(run_touches_protected "$big_pr_protected" "$CO_SAMPLE" 2>&1)" || rc=$?
check_rc "touches_protected an earlier change (>2.5MB pr_json with protected hit rc)" "0" "$rc"
check "touches_protected an earlier change (>2.5MB pr_json -> install.sh)" "install.sh" "$got"

rc=0; got="$(run_touches_protected "$big_pr_clean" "$CO_SAMPLE" 2>&1)" || rc=$?
check_rc "touches_protected an earlier change (>2.5MB pr_json without protected hit rc)" "0" "$rc"
check "touches_protected an earlier change (>2.5MB pr_json -> empty)" "" "$got"

rc=0; got="$(run_decide_pr_gate "$big_pr_clean" "settled_green" "clean" 0 "" 2>&1)" || rc=$?
check_rc "decide_pr_gate an earlier change (>2.5MB pr_json rc)" "0" "$rc"
check "decide_pr_gate an earlier change (>2.5MB pr_json -> 0|OK|1|gate passed)" "0|OK|1|gate passed" "$got"

rc=0; got="$(run_decide_pr_gate "$big_pr_protected" "settled_green" "clean" 0 "install.sh" 2>&1)" || rc=$?
check_rc "decide_pr_gate an earlier change (>2.5MB pr_json protected rc)" "0" "$rc"
check "decide_pr_gate an earlier change (>2.5MB pr_json protected -> NEEDS_OWNER)" "5|NEEDS_OWNER|0|pull request touches protected paths (install.sh)" "$got"

# Regression: SIGPIPE ignored (CI runner) and set -euo pipefail on >64 KiB inputs
rc=0; got="$( (
  set -euo pipefail
  run_evaluate_review_state 1 "head123" "$big_single_review" 0
) 2>&1 )" || rc=$?
check_rc "evaluate_review_state an earlier change (>2.5MB single review body, pipefail rc)" "0" "$rc"
check "evaluate_review_state an earlier change (>2.5MB single review body, pipefail -> clean)" "clean" "$got"

rc=0; got="$( (
  trap '' PIPE
  set -euo pipefail
  run_evaluate_review_state 1 "head123" "$big_single_review" 0
) 2>&1 )" || rc=$?
check_rc "evaluate_review_state an earlier change (>2.5MB single review body, SIGPIPE ignored + pipefail rc)" "0" "$rc"
check "evaluate_review_state an earlier change (>2.5MB single review body, SIGPIPE ignored + pipefail -> clean)" "clean" "$got"

if [ -f "$here/.github/CODEOWNERS" ]; then
  big_plain_files="$(python3 -c '
lines = [f"src/dir{i}/subdir_{i}/file_{i}.sh" for i in range(2500)]
lines.append("lib/pr-gate-core.sh")
lines.append("lib/auto-review-mark.sh")
print("\n".join(lines))
')"
  rc=0; got="$( (
    trap '' PIPE
    set -euo pipefail
    run_touches_protected "$big_plain_files" "$(cat "$here/.github/CODEOWNERS")"
  ) 2>&1 )" || rc=$?
  check_rc "touches_protected an earlier change (>64KB newline list, SIGPIPE ignored + pipefail rc)" "0" "$rc"
  check "touches_protected an earlier change (>64KB newline list, SIGPIPE ignored + pipefail -> protected libs)" \
    "$(printf 'lib/pr-gate-core.sh\nlib/auto-review-mark.sh')" "$got"
fi

big_findings_body="$(python3 -c '
bt = chr(96)
print("\n".join(f"{i}. {bt}f{i}.sh:{i}{bt} msg {i}" for i in range(1, 8)) + "\n" + ("x" * 70000))
')"
rc=0; got="$( (
  trap '' PIPE
  set -euo pipefail
  # shellcheck disable=SC1090
  . "$WATCHER"
  extract_findings "$big_findings_body"
) 2>&1 )" || rc=$?
check_rc "auto-review-watch extract_findings (>64KB, SIGPIPE ignored + pipefail rc)" "0" "$rc"
check "auto-review-watch extract_findings (>64KB, SIGPIPE ignored + pipefail -> first 5)" \
  "$(printf '%s\n' '- `f1.sh:1` msg 1' '- `f2.sh:2` msg 2' '- `f3.sh:3` msg 3' '- `f4.sh:4` msg 4' '- `f5.sh:5` msg 5')" "$got"


# ═════════════════════════════════════════════════════════════════════════════
# 10. Thin I/O helpers & minimal CLI wiring smoke checks (at most 2, zero scratch git repos)
# ═════════════════════════════════════════════════════════════════════════════

tmp_cli="$(mktemp -d)"
trap 'rm -rf "$tmp_cli"' EXIT

# 10.1 detect_auto_review_installed (Thin I/O registry check via source "$GATE")
printf '%s' '{"version":1,"projects":{"acme/webapp":{"enabled":true}}}' >"$tmp_cli/projects.json"
reg_yes="$( (
  export AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json"
  # shellcheck disable=SC1090
  . "$GATE"
  detect_auto_review_installed "acme-webapp" "acme/webapp"
) )"
reg_no="$( (
  export AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json"
  # shellcheck disable=SC1090
  . "$GATE"
  detect_auto_review_installed "unregistered-slug" "owner/unregistered-repo"
) )"
check "detect_auto_review_installed: registered repo returns 1" "1" "$reg_yes"
check "detect_auto_review_installed: unregistered repo returns 0" "0" "$reg_no"

# 10.2 CLI Smoke Check 1: large >2.5 MB paginated PR + an earlier change headRefName wiring
mkdir -p "$tmp_cli/bin"
ln -s "$here/lib" "$tmp_cli/lib"
cp "$GATE" "$tmp_cli/bin/pr-gate.sh"
chmod +x "$tmp_cli/bin/pr-gate.sh"

python3 - "$tmp_cli" <<'PYGEN'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])

pr_105 = {
    "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
    "headRefOid": "head123", "headRefName": "feat/big-pr", "baseRefName": "main",
    "labels": [],
    "files": [{"path": f"src/f{i}.sh"} for i in range(1, 101)],
    "changedFiles": 105,
    "reviews": [],
    "author": {"login": "acme-agent"},
    "body": "<!-- EXECUTORS:START --> ok <!-- EXECUTORS:END -->"
}
(d / "pr_big.json").write_text(json.dumps(pr_105, separators=(",", ":")))

page1 = [{"filename": f"src/f{i}.sh"} for i in range(1, 101)]
page2 = [{"filename": f"src/f{i}_" + ("p" * 540000) + ".sh"} for i in range(101, 106)]
(d / "files_big.json").write_text(json.dumps([page1, page2], separators=(",", ":")))

runs_big = {"total_count": 136, "workflow_runs": [
    {"name": f"c{i}", "status": "completed", "conclusion": "success", "display_title": "t" * 20000}
    for i in range(136)
]}
(d / "runs_big.json").write_text(json.dumps(runs_big, separators=(",", ":")))

revs_big = [{"commit_id": f"old{i}", "body": "note " + ("r" * 40000)} for i in range(68)]
revs_big.append({
    "commit_id": "head123",
    "body": "**No findings.**\n\n---\n_Automated review. Not an approval._",
    "user": {"login": "auto-review"},
    "state": "COMMENTED"
})
(d / "reviews_big.json").write_text(json.dumps(revs_big, separators=(",", ":")))

(d / "pr_384_with_ref.json").write_text(json.dumps({
    "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
    "headRefOid": "head384sha", "headRefName": "changeset-release/master", "baseRefName": "master",
    "labels": [{"name": "release"}],
    "files": [{"path": "CHANGELOG.md"}],
    "changedFiles": 1,
    "reviews": [{"commit_id": "head384sha", "body": "**No findings.**\n\n---\n_Automated review. Not an approval._", "user": {"login": "auto-review"}, "state": "COMMENTED"}],
    "author": {"login": "app/github-actions"},
    "body": "Version Packages"
}, separators=(",", ":")))

(d / "pr_384_no_ref.json").write_text(json.dumps({
    "state": "OPEN", "isDraft": False, "mergeable": "MERGEABLE",
    "headRefOid": "head384sha", "baseRefName": "master",
    "labels": [{"name": "release"}],
    "files": [{"path": "CHANGELOG.md"}],
    "changedFiles": 1,
    "reviews": [{"commit_id": "head384sha", "body": "**No findings.**\n\n---\n_Automated review. Not an approval._", "user": {"login": "auto-review"}, "state": "COMMENTED"}],
    "author": {"login": "app/github-actions"},
    "body": "Version Packages"
}, separators=(",", ":")))

(d / "runs_384.json").write_text(json.dumps({
    "total_count": 2,
    "workflow_runs": [
        {"name": "CI", "event": "pull_request", "status": "completed", "conclusion": "action_required", "head_branch": "changeset-release/master", "head_sha": "head384sha"},
        {"name": "Release verify", "event": "workflow_dispatch", "status": "completed", "conclusion": "success", "head_branch": "changeset-release/master", "head_sha": "head384sha"}
    ]
}, separators=(",", ":")))

(d / "reviews_384.json").write_text(json.dumps([{
    "commit_id": "head384sha",
    "body": "**No findings.**\n\n---\n_Automated review. Not an approval._",
    "user": {"login": "auto-review"},
    "state": "COMMENTED"
}], separators=(",", ":")))

(d / "runs_ok.json").write_text('{"workflow_runs":[{"name":"check","status":"completed","conclusion":"success"}]}')
(d / "reviews_ok.json").write_text('[{"commit_id":"head123","body":"**No findings.**\\n\\n---\\n_Automated review. Not an approval._","user":{"login":"auto-review"},"state":"COMMENTED"}]')
PYGEN

cat >"$tmp_cli/bin/gh" <<'STUBGH_CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_GH_LOG"
has_slurp=0
has_filter=0
for arg in "$@"; do
  case "$arg" in
    --slurp) has_slurp=1 ;;
    -q|-q=*|--jq|--jq=*|-t|-t=*|--template|--template=*) has_filter=1 ;;
  esac
done
if [ "$has_slurp" = 1 ] && [ "$has_filter" = 1 ]; then
  echo "the --slurp option is not supported with --jq or --template" >&2
  exit 1
fi

case "$*" in
  *"pr view "*)
    if [ "${STUB_MODE:-}" = "watch" ] || [ "${STUB_MODE:-}" = "merge" ]; then
      cnt=0
      [ -f "$STUB_VIEW_COUNT" ] && cnt=$(cat "$STUB_VIEW_COUNT")
      cnt=$((cnt + 1))
      printf '%d\n' "$cnt" >"$STUB_VIEW_COUNT"
      src="$STUB_PR_INITIAL"
      [ "$cnt" -ge 2 ] && [ -n "${STUB_PR_RECHECK:-}" ] && src="$STUB_PR_RECHECK"
      jq_filter=""
      prev=""
      for arg in "$@"; do
        [ "$prev" = "--jq" ] && jq_filter="$arg"
        prev="$arg"
      done
      if [ -n "$jq_filter" ]; then
        jq -r "$jq_filter" "$src"
      else
        cat "$src"
      fi
    elif [ "${STUB_MODE:-}" = "cli384" ]; then
      case "$*" in
        *headRefName*) cat "$STUB_PR_WITH_REF" ;;
        *) cat "$STUB_PR_NO_REF" ;;
      esac
    else
      cat "$STUB_PR_JSON"
    fi
    ;;
  *"pulls/42/files"*)
    [ "$has_slurp" = 1 ] || exit 1
    cat "$STUB_FILES_JSON"
    ;;
  *"actions/runs"*)
    if [ -n "${STUB_WATCH_STATE_FILE:-}" ]; then
      phase=$(cat "$STUB_WATCH_STATE_FILE" 2>/dev/null || echo "pre")
      case "$phase" in
        pre)
          printf '%s\n' '{"workflow_runs":[{"name":"check","status":"in_progress","conclusion":null}]}'
          if [ -n "${STUB_POST_WATCH_PHASE:-}" ]; then
            printf '%s\n' "$STUB_POST_WATCH_PHASE" >"$STUB_WATCH_STATE_FILE"
          fi
          ;;
        post_ok) printf '%s\n' '{"workflow_runs":[{"name":"check","status":"completed","conclusion":"success"}]}' ;;
        post_fail) printf '%s\n' '{"workflow_runs":[{"name":"unit-tests","status":"completed","conclusion":"failure"}]}' ;;
      esac
    else
      cat "$STUB_RUNS_JSON"
    fi
    ;;
  *"commits/"*"/status"*)
    printf '%s\n' '{"state":"success","statuses":[]}'
    ;;
  *"/reviews"*)
    if [ -n "${STUB_WATCH_STATE_FILE:-}" ]; then
      phase=$(cat "$STUB_WATCH_STATE_FILE" 2>/dev/null || echo "pre")
      case "$phase" in
        pre) printf '%s\n' '[]' ;;
        *) printf '%s\n' '[{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._","user":{"login":"auto-review"},"state":"COMMENTED"}]' ;;
      esac
    else
      if [ "$has_slurp" = 1 ]; then
        printf '[%s]\n' "$(cat "$STUB_REVIEWS_JSON")"
      else
        cat "$STUB_REVIEWS_JSON"
      fi
    fi
    ;;
  *"contents/.github/CODEOWNERS"*)
    printf '/install.sh @hanzhad\n/agents/hooks/ @hanzhad\n'
    ;;
  *"pr merge "*)
    for arg in "$@"; do
      if [ "$arg" = "--admin" ]; then
        exit 0
      fi
    done
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
STUBGH_CLI
chmod +x "$tmp_cli/bin/gh"

cat >"$tmp_cli/bin/auto-review-watch.sh" <<'STUBWATCH_CLI'
#!/usr/bin/env bash
printf '%s\n' "$STUB_POST_WATCH_PHASE" >"$STUB_WATCH_STATE_FILE"
printf '[auto-review-watch] Clean\n'
exit 0
STUBWATCH_CLI
chmod +x "$tmp_cli/bin/auto-review-watch.sh"

# Smoke 1A: CLI with >2.5 MB paginated files, >2.5 MB reviews, >2.5 MB workflow_runs
: >"$tmp_cli/gh.log"
cli1a_rc=0
cli1a_out="$(cd "$tmp_cli" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_MODE="cli361" STUB_GH_LOG="$tmp_cli/gh.log" \
  STUB_PR_JSON="$tmp_cli/pr_big.json" STUB_FILES_JSON="$tmp_cli/files_big.json" \
  STUB_RUNS_JSON="$tmp_cli/runs_big.json" STUB_REVIEWS_JSON="$tmp_cli/reviews_big.json" \
  PATH="$tmp_cli/bin:$PATH" bash "$tmp_cli/bin/pr-gate.sh" 42 --repo acme/webapp 2>&1)" || cli1a_rc=$?
check_rc "CLI smoke an earlier change (>2.5MB paginated PR) exits 0" "0" "$cli1a_rc"
check "CLI smoke an earlier change (>2.5MB paginated PR) -> 0|OK|1|gate passed" "0|OK|1|gate passed" "$cli1a_out"

# Smoke 1B: CLI fetches headRefName and passes an earlier change changeset-release/master PR
: >"$tmp_cli/gh.log"
cli1b_rc=0
cli1b_out="$(cd "$tmp_cli" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_MODE="cli384" STUB_GH_LOG="$tmp_cli/gh.log" \
  STUB_PR_WITH_REF="$tmp_cli/pr_384_with_ref.json" STUB_PR_NO_REF="$tmp_cli/pr_384_no_ref.json" \
  STUB_RUNS_JSON="$tmp_cli/runs_384.json" STUB_REVIEWS_JSON="$tmp_cli/reviews_384.json" \
  PATH="$tmp_cli/bin:$PATH" bash "$tmp_cli/bin/pr-gate.sh" 42 --repo acme/webapp 2>&1)" || cli1b_rc=$?
check_rc "CLI smoke an earlier change (changeset-release/master + headRefName) exits 0" "0" "$cli1b_rc"
check "CLI smoke an earlier change (changeset-release/master + headRefName) -> 0|OK|1|gate passed" "0|OK|1|gate passed" "$cli1b_out"

# Smoke 2: CLI --watch refreshes CI after watcher returns, and --merge re-checks mergeability before --admin
printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","headRefOid":"head123","baseRefName":"main","labels":[],"files":[{"path":"src/app.sh"}],"reviews":[],"author":{"login":"acme-agent"},"body":"<!-- EXECUTORS:START --> ok <!-- EXECUTORS:END -->"}' >"$tmp_cli/pr_ok.json"
printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"CONFLICTING","headRefOid":"head123","baseRefName":"main","labels":[],"files":[{"path":"src/app.sh"}],"reviews":[],"author":{"login":"acme-agent"},"body":"<!-- EXECUTORS:START --> ok <!-- EXECUTORS:END -->"}' >"$tmp_cli/pr_conflicting.json"

printf 'pre\n' >"$tmp_cli/watch_phase"
: >"$tmp_cli/gh.log"
w_rc=0
w_raw="$(cd "$tmp_cli" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_MODE="watch" STUB_GH_LOG="$tmp_cli/gh.log" STUB_VIEW_COUNT="$tmp_cli/view_count_w" \
  STUB_PR_INITIAL="$tmp_cli/pr_ok.json" STUB_WATCH_STATE_FILE="$tmp_cli/watch_phase" \
  STUB_POST_WATCH_PHASE="post_ok" PR_GATE_POLL_INTERVAL=1 PR_GATE_DOCKER_AVAILABLE=0 \
  PATH="$tmp_cli/bin:$PATH" \
  bash "$tmp_cli/bin/pr-gate.sh" 42 --repo acme/webapp --watch 2>&1)" || w_rc=$?
w_last="$(printf '%s\n' "$w_raw" | tail -n 1)"
check_rc "CLI smoke --watch refresh exits 0" "0" "$w_rc"
check "CLI smoke --watch refresh -> 0|OK|1|gate passed" "0|OK|1|gate passed" "$w_last"

: >"$tmp_cli/gh.log"
printf '0\n' >"$tmp_cli/view_count_m"
m_rc=0
m_out="$(cd "$tmp_cli" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_MODE="merge" STUB_GH_LOG="$tmp_cli/gh.log" STUB_VIEW_COUNT="$tmp_cli/view_count_m" \
  STUB_PR_INITIAL="$tmp_cli/pr_ok.json" STUB_PR_RECHECK="$tmp_cli/pr_conflicting.json" \
  STUB_RUNS_JSON="$tmp_cli/runs_ok.json" STUB_REVIEWS_JSON="$tmp_cli/reviews_ok.json" \
  PATH="$tmp_cli/bin:$PATH" bash "$tmp_cli/bin/pr-gate.sh" 42 --repo acme/webapp --merge 2>&1)" || m_rc=$?
check_rc "CLI smoke --merge recheck CONFLICTING exits 3" "3" "$m_rc"
check_prefix "CLI smoke --merge recheck CONFLICTING outputs 3|FIX_CONFLICTS|0|" "3|FIX_CONFLICTS|0|" "$m_out"
if grep -q 'pr merge ' "$tmp_cli/gh.log" && ! grep -q -- '--admin' "$tmp_cli/gh.log"; then
  pass "CLI smoke --merge recheck CONFLICTING does not call --admin"
else
  fail_case "CLI smoke --merge recheck CONFLICTING does not call --admin" "no --admin in gh log" "$(cat "$tmp_cli/gh.log")"
fi

: >"$tmp_cli/gh.log"
printf '0\n' >"$tmp_cli/view_count_m2"
m2_rc=0
m2_out="$(cd "$tmp_cli" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_MODE="merge" STUB_GH_LOG="$tmp_cli/gh.log" STUB_VIEW_COUNT="$tmp_cli/view_count_m2" \
  STUB_PR_INITIAL="$tmp_cli/pr_ok.json" STUB_PR_RECHECK="$tmp_cli/pr_ok.json" \
  STUB_RUNS_JSON="$tmp_cli/runs_ok.json" STUB_REVIEWS_JSON="$tmp_cli/reviews_ok.json" \
  PATH="$tmp_cli/bin:$PATH" bash "$tmp_cli/bin/pr-gate.sh" 42 --repo acme/webapp --merge 2>&1)" || m2_rc=$?
check_rc "CLI smoke --merge recheck MERGEABLE exits 0" "0" "$m2_rc"
check "CLI smoke --merge recheck MERGEABLE -> 0|OK|1|gate passed" "0|OK|1|gate passed" "$m2_out"

# ═════════════════════════════════════════════════════════════════════════════
# 11. Pure Core pr_gate_watch_core.py: state-machine, health, backoff, ETag
# ═════════════════════════════════════════════════════════════════════════════

watch_py_rc=0
PYTHONDONTWRITEBYTECODE=1 python3 - "$here" <<'PY' || watch_py_rc=$?
import ast, importlib.util, json, pathlib, sys, unittest

ROOT = pathlib.Path(sys.argv[1]).resolve()
WATCH_CORE_PATH = ROOT / "lib" / "pr_gate_watch_core.py"


def _load_watch_core(tc):
    tc.assertTrue(WATCH_CORE_PATH.is_file(), f"Expected Pure Core module at {WATCH_CORE_PATH}")
    spec = importlib.util.spec_from_file_location("pr_gate_watch_core", str(WATCH_CORE_PATH))
    tc.assertIsNotNone(spec)
    tc.assertIsNotNone(spec.loader)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _sm(core, **kw):
    d = dict(
        repo="acme/webapp", pr=42, head_sha="abc1234",
        fail_fast_ci=False, fail_fast_ci_grace_s=20, wait_all_ci=False,
        ci_runner=0, docker_available=True, ci_max_wait_s=1800,
        review_pickup_timeout_s=600, review_queue_ceiling_s=1800,
        auto_review_installed=True, registry_project={"enabled": True, "paused": False},
        pr_branch="feat/issue-469", pr_labels=[], workflows_present=True, only_base_merges=False,
    )
    d.update(kw)
    return core.WatchStateMachine(**d)


def _snap(**kw):
    d = dict(
        head_sha="abc1234", gate_decision="2|WAIT_CI|0|CI is still running on head",
        ci_state="pending", review_state="wait_review", runs=[], jobs_by_run={},
        ci_runner_inspect=None, ci_runner_status=None, ci_runner_logs="",
        auto_review_inspect=None, auto_review_status=None, auto_review_logs="", api_error=None,
    )
    d.update(kw)
    return d


class PrGateWatchCoreTest(unittest.TestCase):
    def test_pure_core_isolation_and_bytecode_invariant(self):
        self.assertTrue(WATCH_CORE_PATH.is_file(), f"Expected Pure Core module at {WATCH_CORE_PATH}")
        tree = ast.parse(WATCH_CORE_PATH.read_text(encoding="utf-8"), filename=str(WATCH_CORE_PATH))
        forbidden = {"subprocess", "socket", "urllib", "http", "shutil", "pathlib"}
        saw_no_pyc = False
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for a in node.names:
                    self.assertNotIn(a.name.split(".", 1)[0], forbidden)
            elif isinstance(node, ast.ImportFrom) and node.module:
                self.assertNotIn(node.module.split(".", 1)[0], forbidden)
            elif isinstance(node, ast.Assign):
                for t in node.targets:
                    if (isinstance(t, ast.Attribute) and isinstance(t.value, ast.Name)
                            and t.value.id == "sys" and t.attr == "dont_write_bytecode"
                            and isinstance(node.value, ast.Constant) and node.value.value is True):
                        saw_no_pyc = True
        self.assertTrue(saw_no_pyc, "pr_gate_watch_core.py must set sys.dont_write_bytecode = True")
        core = _load_watch_core(self)
        for sym in ("WatchStateMachine", "build_ndjson_event", "scrub_secrets",
                    "compute_poll_interval", "build_etag_headers", "handle_http_response"):
            self.assertTrue(callable(getattr(core, sym, None)), f"missing {sym}")

    def test_ndjson_schema_and_transition_only_emission(self):
        core = _load_watch_core(self)
        ev = core.build_ndjson_event(
            ts="2026-11-25T00:00:00Z", repo="acme/webapp", pr=42, head_sha="abc1234",
            phase="ci", event="ci_waiting", severity="info", code="WAIT_CI",
            summary="CI running", diagnostic={"queued": 1}, gate="2|WAIT_CI|0|CI is still running on head",
        )
        self.assertEqual(ev["schema"], 1)
        self.assertEqual((ev["repo"], ev["pr"], ev["severity"], ev["code"]), ("acme/webapp", 42, "info", "WAIT_CI"))
        self.assertEqual(ev["diagnostic"], {"queued": 1})
        ev_min = core.build_ndjson_event(
            ts="2026-11-25T00:00:00Z", repo="acme/webapp", pr=42, head_sha="abc1234",
            phase="ci", event="tick", severity="info", code="WAIT_CI", summary="tick",
        )
        self.assertNotIn("diagnostic", ev_min)
        self.assertNotIn("gate", ev_min)
        sm = _sm(core)
        r1 = sm.step(0, _snap())
        self.assertFalse(r1["terminal"])
        self.assertGreaterEqual(len(r1["events"]), 1)
        self.assertEqual(sm.step(15, _snap())["events"], [])

    def test_preflight_fail_fast_vs_grace_table(self):
        core = _load_watch_core(self)
        for gate_line, want_code, want_status in [
            ("3|NOT_OPEN|0|pull request is not open", 3, "NOT_OPEN"),
            ("3|DRAFT|0|pull request is a draft", 3, "DRAFT"),
            ("3|FIX_CONFLICTS|0|pull request has merge conflicts", 3, "FIX_CONFLICTS"),
            ("5|NEEDS_OWNER|0|pull request touches .github/workflows", 5, "NEEDS_OWNER"),
            ("3|FIX_CI|0|CI failed on head (check)", 3, "FIX_CI"),
            ("3|FIX_FINDINGS|0|review findings open on current head", 3, "FIX_FINDINGS"),
            ("0|OK|1|gate passed", 0, "OK"),
        ]:
            with self.subTest(status=want_status):
                res = _sm(core).step(0, _snap(gate_decision=gate_line))
                self.assertTrue(res["terminal"])
                self.assertEqual((res["exit_code"], res["status"], res["gate_line"]), (want_code, want_status, gate_line))
                self.assertEqual(res["events"][-1]["severity"], "terminal")

        sm_m = _sm(core)
        self.assertFalse(sm_m.step(0, _snap(gate_decision="2|WAIT_MERGEABLE|0|wait", ci_state="settled_green", review_state="clean"))["terminal"])
        r_ok = sm_m.step(15, _snap(gate_decision="0|OK|1|gate passed", ci_state="settled_green", review_state="clean"))
        self.assertTrue(r_ok["terminal"])
        self.assertEqual((r_ok["exit_code"], r_ok["status"]), (0, "OK"))

        noci_gate = "4|NEEDS_META|0|no CI configured for commit; meta must verify diff"
        sm_wf = _sm(core, workflows_present=True)
        r0 = sm_wf.step(0, _snap(gate_decision=noci_gate, ci_state="settled_no_ci"))
        self.assertFalse(r0["terminal"])
        self.assertEqual(r0["events"][-1]["phase"], "ci_awaiting_registration")
        self.assertFalse(sm_wf.step(59, _snap(gate_decision=noci_gate, ci_state="settled_no_ci"))["terminal"])
        r60 = sm_wf.step(60, _snap(gate_decision=noci_gate, ci_state="settled_no_ci"))
        self.assertTrue(r60["terminal"])
        self.assertEqual((r60["exit_code"], r60["status"]), (4, "NEEDS_META"))
        self.assertEqual(r60["events"][-1]["diagnostic"], {"workflows_present": True, "ci_registration_timed_out": True})

        sm_rec = _sm(core, workflows_present=True)
        sm_rec.step(0, _snap(gate_decision=noci_gate, ci_state="settled_no_ci"))
        r_reg = sm_rec.step(30, _snap(runs=[{"id": 101, "name": "ci", "status": "in_progress", "conclusion": None}]))
        self.assertFalse(r_reg["terminal"])
        self.assertEqual(r_reg["events"][-1]["phase"], "ci")

        r_noci = _sm(core, workflows_present=False).step(0, _snap(gate_decision=noci_gate, ci_state="settled_no_ci"))
        self.assertTrue(r_noci["terminal"])
        self.assertEqual((r_noci["exit_code"], r_noci["status"]), (4, "NEEDS_META"))
        self.assertFalse((r_noci["events"][-1].get("diagnostic") or {}).get("ci_registration_timed_out", False))

        r_base = _sm(core, only_base_merges=True).step(0, _snap(gate_decision="0|OK|1|gate passed", ci_state="settled_green", review_state="clean"))
        self.assertTrue(r_base["terminal"])
        self.assertEqual(r_base["exit_code"], 0)

    def test_head_drifted_immediate_terminal_exit(self):
        core = _load_watch_core(self)
        sm = _sm(core, head_sha="aaa1111")
        self.assertFalse(sm.step(0, _snap(head_sha="aaa1111"))["terminal"])
        r1 = sm.step(15, _snap(head_sha="bbb2222"))
        self.assertTrue(r1["terminal"])
        self.assertEqual((r1["exit_code"], r1["status"]), (6, "HEAD_DRIFTED"))
        self.assertTrue(r1["gate_line"].startswith("6|HEAD_DRIFTED|0|"))
        self.assertEqual(r1["events"][-1]["diagnostic"], {"old_sha": "aaa1111", "new_sha": "bbb2222"})

    def test_fail_fast_ci_debounce_vs_wait_all_ci(self):
        core = _load_watch_core(self)
        runs = [{"id": 10, "name": "unit", "status": "completed", "conclusion": "failure"},
                {"id": 11, "name": "e2e", "status": "in_progress", "conclusion": None}]
        jobs = {10: [{"id": 1001, "name": "unit (3.11)", "status": "completed", "conclusion": "failure", "failed_step": "pytest"},
                     {"id": 1002, "name": "unit (3.12)", "status": "completed", "conclusion": "success"}],
                11: [{"id": 1101, "name": "e2e", "status": "in_progress", "conclusion": None}]}
        sm_ff = _sm(core, fail_fast_ci=True, fail_fast_ci_grace_s=15)
        r0 = sm_ff.step(0, _snap(runs=runs, jobs_by_run=jobs))
        self.assertFalse(r0["terminal"])
        adv = [e for e in r0["events"] if e["event"] == "ci_job_failed_early"]
        self.assertEqual(len(adv), 1)
        self.assertEqual(adv[0]["severity"], "advisory")
        self.assertEqual((len(adv[0]["diagnostic"]["failed_jobs"]), len(adv[0]["diagnostic"]["pending_jobs"]), len(adv[0]["diagnostic"]["passed_jobs"])), (1, 1, 1))
        r14 = sm_ff.step(14, _snap(runs=runs, jobs_by_run=jobs))
        self.assertFalse(r14["terminal"])
        self.assertEqual([e for e in r14["events"] if e["event"] == "ci_job_failed_early"], [])
        r15 = sm_ff.step(15, _snap(runs=runs, jobs_by_run=jobs))
        self.assertTrue(r15["terminal"])
        self.assertEqual((r15["exit_code"], r15["status"]), (3, "FIX_CI"))

        sm_w = _sm(core, fail_fast_ci=False, wait_all_ci=True)
        sm_w.step(0, _snap(runs=runs, jobs_by_run=jobs))
        self.assertFalse(sm_w.step(30, _snap(runs=runs, jobs_by_run=jobs))["terminal"])
        r45 = sm_w.step(45, _snap(gate_decision="3|FIX_CI|0|CI failed on head (unit)", ci_state="failed:unit",
                                   runs=[{"id": 10, "name": "unit", "status": "completed", "conclusion": "failure"},
                                         {"id": 11, "name": "e2e", "status": "completed", "conclusion": "success"}]))
        self.assertTrue(r45["terminal"])
        self.assertEqual((r45["exit_code"], r45["status"]), (3, "FIX_CI"))

    def test_ci_runner_health_and_github_scheduling_stall_table(self):
        core = _load_watch_core(self)
        q_runs = [{"id": 20, "name": "ci", "status": "queued", "conclusion": None}]
        ok_insp = {"State": {"Status": "running", "Running": True}, "RestartCount": 0}
        free_st = {"ts": "2026-11-25T00:03:00Z", "locked": False, "paused": False, "waiting": None, "draining": None, "used": 1, "budget": 4, "queue": []}

        sm_p = _sm(core, ci_runner=1, docker_available=True)
        self.assertFalse(sm_p.step(0, _snap(runs=q_runs))["need_ci_runner_inspect"])
        self.assertTrue(sm_p.step(31, _snap(runs=q_runs))["need_ci_runner_inspect"])
        self.assertFalse(sm_p.step(45, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status=free_st))["need_ci_runner_inspect"])

        for code, insp, st, logs in [
            ("CI_RUNNER_DOWN", {"State": {"Status": "exited", "Running": False}, "RestartCount": 1}, None, "ghp_secretTok123456\nerr"),
            ("CI_RUNNER_LOCKED", ok_insp, {**free_st, "locked": True}, ""),
            ("CI_RUNNER_PAUSED", ok_insp, {**free_st, "paused": True}, ""),
        ]:
            with self.subTest(code=code):
                sm_i = _sm(core, ci_runner=1, docker_available=True)
                sm_i.step(0, _snap(runs=q_runs))
                res = sm_i.step(35, _snap(runs=q_runs, ci_runner_inspect=insp, ci_runner_status=st, ci_runner_logs=logs))
                self.assertTrue(res["terminal"])
                self.assertEqual((res["status"], res["events"][-1]["code"]), ("BLOCKED_INFRA", code))
                if logs:
                    self.assertNotIn("ghp_secretTok123456", json.dumps(res["events"][-1]))

        for key, busy_st in [
            ("waiting", {**free_st, "waiting": "memory"}),
            ("draining", {**free_st, "draining": {"repo": "other/repo"}}),
            ("budget", {**free_st, "used": 4, "budget": 4}),
        ]:
            with self.subTest(busy=key):
                sm_b = _sm(core, ci_runner=1, docker_available=True)
                sm_b.step(0, _snap(runs=q_runs))
                rb = sm_b.step(200, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status=busy_st))
                self.assertFalse(rb["terminal"])
                self.assertNotIn("CI_GITHUB_SCHEDULING_STALLED", [e["code"] for e in rb["events"]])

        sm_ls = _sm(core, ci_runner=1, docker_available=True)
        sm_ls.step(0, _snap(runs=q_runs))
        self.assertNotIn("CI_GITHUB_SCHEDULING_STALLED", [e["code"] for e in sm_ls.step(179, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status=free_st))["events"]])
        r180 = sm_ls.step(180, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status=free_st))
        st_evs = [e for e in r180["events"] if e["code"] == "CI_GITHUB_SCHEDULING_STALLED"]
        self.assertEqual(len(st_evs), 1)
        self.assertTrue(st_evs[0]["diagnostic"]["runner_healthy"])
        self.assertFalse(sm_ls.step(899, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status=free_st))["terminal"])
        r900 = sm_ls.step(900, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status=free_st))
        self.assertTrue(r900["terminal"])
        self.assertEqual((r900["status"], r900["events"][-1]["code"]), ("BLOCKED_INFRA", "CI_GITHUB_SCHEDULING_TIMEOUT"))

        sm_gs = _sm(core, ci_runner=0, docker_available=False)
        sm_gs.step(0, _snap(runs=q_runs))
        self.assertNotIn("CI_GITHUB_SCHEDULING_STALLED", [e["code"] for e in sm_gs.step(299, _snap(runs=q_runs))["events"]])
        self.assertIn("CI_GITHUB_SCHEDULING_STALLED", [e["code"] for e in sm_gs.step(300, _snap(runs=q_runs))["events"]])
        self.assertEqual(sm_gs.step(900, _snap(runs=q_runs))["events"][-1]["code"], "CI_GITHUB_SCHEDULING_TIMEOUT")

        sm_persist = _sm(core, ci_runner=1, docker_available=True)
        sm_persist.step(0, _snap(runs=q_runs))
        self.assertFalse(sm_persist.step(35, _snap(runs=q_runs, ci_runner_inspect=ok_insp, ci_runner_status={**free_st, "waiting": "memory"}))["terminal"])
        for t_poll in list(range(50, 1000, 30)) + [1000]:
            rp = sm_persist.step(t_poll, _snap(runs=q_runs, ci_runner_inspect=None))
            self.assertFalse(rp["terminal"])
            self.assertNotIn("CI_GITHUB_SCHEDULING_STALLED", [e["code"] for e in rp["events"]])
            self.assertNotIn("CI_GITHUB_SCHEDULING_TIMEOUT", [e["code"] for e in rp["events"]])

    def test_review_phase_timers_registry_status_and_docker_table(self):
        core = _load_watch_core(self)
        ar_ok = {"State": {"Status": "running", "Running": True, "Restarting": False}, "RestartCount": 0}
        st_ok = {"phase": "idle", "active": [], "queued": [], "last_tick_at": 1000, "interval_s": 180, "recent_results": {}, "tick_errors": {}}
        rev_snap = lambda **k: _snap(ci_state="settled_green", review_state="wait_review", gate_decision="2|WAIT_REVIEW|0|wait", **k)

        sm = _sm(core, review_pickup_timeout_s=600, review_queue_ceiling_s=1800)
        sm.step(0, _snap())
        r_rev = sm.step(700, rev_snap(auto_review_inspect=ar_ok, auto_review_status={**st_ok, "last_tick_at": 680}))
        self.assertFalse(r_rev["terminal"])
        self.assertEqual(r_rev["events"][-1]["phase"], "review")
        self.assertFalse(sm.step(1350, rev_snap(auto_review_inspect=ar_ok, auto_review_status={**st_ok, "phase": "scanning", "last_tick_at": 1340}))["terminal"])
        act = [{"repo": "acme/webapp", "pr": 42, "sha": "abc1234", "timeout_s": 900}]
        self.assertFalse(sm.step(1400, rev_snap(auto_review_inspect=ar_ok, auto_review_status={**st_ok, "phase": "reviewing", "last_tick_at": 1390, "active": act}))["terminal"])
        self.assertFalse(sm.step(2419, rev_snap(auto_review_inspect=ar_ok, auto_review_status={**st_ok, "phase": "reviewing", "last_tick_at": 2400, "active": act}))["terminal"])

        for name, rp, br, lbl in [
            ("paused", {"enabled": True, "paused": True}, "feat/x", []),
            ("disabled", {"enabled": False, "paused": False}, "feat/x", []),
            ("skip_branch", {"enabled": True, "paused": False, "skip_branch": "chore/*"}, "chore/deps", []),
            ("skip_label", {"enabled": True, "paused": False, "skip_label": "skip-review"}, "feat/x", ["skip-review"]),
        ]:
            with self.subTest(reg=name):
                rr = _sm(core, registry_project=rp, pr_branch=br, pr_labels=lbl).step(0, rev_snap())
                self.assertTrue(rr["terminal"])
                self.assertEqual(rr["status"], "BLOCKED_INFRA")

        for cname, patch in [
            ("token_invalid", {"tick_errors": {"acme/webapp": {"error_kind": "token_invalid", "reason": "bad", "retryable": False}}}),
            ("github_rejected", {"recent_results": {"acme/webapp#42": {"sha": "abc1234", "result": "error", "error_kind": "github_rejected", "reason": "403", "retryable": False}}}),
            ("stale_tick", {"last_tick_at": 100, "interval_s": 180, "active": []}),
        ]:
            with self.subTest(case=cname):
                rnr = _sm(core).step(1000, rev_snap(auto_review_inspect=ar_ok, auto_review_status={**st_ok, "last_tick_at": 990, **patch}))
                self.assertTrue(rnr["terminal"])
                self.assertEqual(rnr["status"], "BLOCKED_INFRA")

        sm_ret = _sm(core)
        for t, att in [(1000, 1), (1110, 2)]:
            rr = sm_ret.step(t, rev_snap(auto_review_inspect=ar_ok, auto_review_status={
                **st_ok, "last_tick_at": t - 10,
                "recent_results": {"acme/webapp#42": {"sha": "abc1234", "result": "error", "error_kind": "rate_limit", "reason": "429", "retryable": True, "attempts": att}},
            }))
            self.assertFalse(rr["terminal"])
            self.assertTrue(any(e["severity"] == "advisory" for e in rr["events"]))
        r_e3 = sm_ret.step(1210, rev_snap(auto_review_inspect=ar_ok, auto_review_status={
            **st_ok, "last_tick_at": 1200,
            "recent_results": {"acme/webapp#42": {"sha": "abc1234", "result": "error", "error_kind": "rate_limit", "reason": "429", "retryable": True, "attempts": 3}},
        }))
        self.assertTrue(r_e3["terminal"])
        self.assertEqual(r_e3["status"], "BLOCKED_INFRA")

        r_dead = _sm(core, docker_available=True).step(0, rev_snap(
            auto_review_inspect={"State": {"Status": "restarting", "Running": False, "Restarting": True}, "RestartCount": 4},
            auto_review_logs="Bearer ghs_secret987654\npanic",
        ))
        self.assertTrue(r_dead["terminal"])
        self.assertEqual(r_dead["events"][-1]["code"], "AUTO_REVIEW_DAEMON_DOWN")
        self.assertNotIn("ghs_secret987654", json.dumps(r_dead["events"][-1]))

        sm_nd = _sm(core, docker_available=False)
        r_nd1 = sm_nd.step(0, rev_snap())
        self.assertFalse(r_nd1["terminal"])
        self.assertTrue(any(e["severity"] == "info" for e in r_nd1["events"]))
        self.assertEqual(sm_nd.step(15, rev_snap())["events"], [])

    def test_transient_api_backoff_recovery_and_etag_304(self):
        core = _load_watch_core(self)
        self.assertEqual(core.build_etag_headers('"e1"').get("If-None-Match"), '"e1"')
        r304 = core.handle_http_response(304, "", {}, {"body": '{"ok":1}', "etag": '"e1"'})
        self.assertTrue(r304["not_modified"])
        self.assertEqual(r304["body"], '{"ok":1}')
        self.assertAlmostEqual(core.compute_poll_interval(0, jitter_factor=0.0), 15.0)
        self.assertAlmostEqual(core.compute_poll_interval(10, jitter_factor=0.2), 36.0)
        self.assertAlmostEqual(core.compute_poll_interval(10, jitter_factor=-0.2), 24.0)

        sm = _sm(core)
        sm.step(0, _snap())
        r1 = sm.step(15, _snap(api_error="502"))
        self.assertEqual((r1["terminal"], r1["next_poll_s"]), (False, 5))
        r2 = sm.step(20, _snap(api_error="502"))
        self.assertEqual(r2["next_poll_s"], 10)
        self.assertEqual(len([e for e in r2["events"] if e["severity"] == "advisory"]), 1)
        self.assertEqual(sm.step(30, _snap(api_error="502"))["next_poll_s"], 20)
        self.assertEqual(sm.step(50, _snap(api_error="502"))["next_poll_s"], 30)
        r_rec = sm.step(80, _snap(api_error=None))
        self.assertTrue(any(e["severity"] == "info" for e in r_rec["events"]))

        sm2 = _sm(core)
        sm2.step(0, _snap())
        for i in range(1, 6):
            self.assertFalse(sm2.step(i * 30, _snap(api_error="503"))["terminal"])
        r6 = sm2.step(180, _snap(api_error="503"))
        self.assertTrue(r6["terminal"])
        self.assertEqual(r6["status"], "BLOCKED_INFRA")


suite = unittest.defaultTestLoader.loadTestsFromTestCase(PrGateWatchCoreTest)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY
if [ "$watch_py_rc" -eq 0 ]; then
  pass "pr_gate_watch_core.py Pure Core unittest suite"
else
  fail_case "pr_gate_watch_core.py Pure Core unittest suite" "exit 0" "exit $watch_py_rc"
fi


# ═════════════════════════════════════════════════════════════════════════════
# 12. an earlier change Thin CLI wiring & security invariants (pr-gate.sh & auto-review-watch.sh)
# ═════════════════════════════════════════════════════════════════════════════

if grep -qE -- '--notify-session|agentapi[[:space:]]+send-message' "$GATE"; then
  fail_case "an earlier change pr-gate.sh forbids --notify-session / agentapi send-message" "absent" "found forbidden reference"
else
  pass "an earlier change pr-gate.sh forbids --notify-session / agentapi send-message"
fi

if grep -qF '.Config.Env' "$GATE"; then
  fail_case "an earlier change pr-gate.sh never reads .Config.Env via docker inspect" "absent" "found .Config.Env"
else
  pass "an earlier change pr-gate.sh never reads .Config.Env via docker inspect"
fi

if grep -qE 'pr-gate\.sh|pr_gate_watch_core' "$WATCHER"; then
  pass "an earlier change auto-review-watch.sh delegates to shared watch core"
else
  fail_case "an earlier change auto-review-watch.sh delegates to shared watch core" \
    "delegates to pr-gate.sh or pr_gate_watch_core" "still standalone loop"
fi

cat >"$tmp_cli/bin/gh_watch469" <<'STUBGH_W469'
#!/usr/bin/env bash
case "$*" in
  *"pr view "*)
    cnt=0
    [ -f "$STUB_W_COUNT" ] && cnt=$(cat "$STUB_W_COUNT")
    cnt=$((cnt + 1))
    printf '%d\n' "$cnt" >"$STUB_W_COUNT"
    if [ "${STUB_W_MODE:-}" = "drift" ] && [ "$cnt" -ge 2 ]; then
      sed 's/"head123"/"head999"/g' "$STUB_PR_INITIAL"
    else
      cat "$STUB_PR_INITIAL"
    fi
    ;;
  *"runs/10/jobs"*) printf '%s\n' '{"jobs":[{"id":1001,"name":"unit","status":"completed","conclusion":"failure"}]}' ;;
  *"runs/11/jobs"*) printf '%s\n' '{"jobs":[{"id":1101,"name":"e2e","status":"in_progress","conclusion":null}]}' ;;
  *"actions/runs"*)
    if [ "${STUB_W_MODE:-}" = "failfast" ]; then
      printf '%s\n' '{"total_count":2,"workflow_runs":[{"id":10,"name":"unit","status":"completed","conclusion":"failure"},{"id":11,"name":"e2e","status":"in_progress","conclusion":null}]}'
    else
      printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":10,"name":"check","status":"in_progress","conclusion":null}]}'
    fi
    ;;
  *"commits/"*"/status"*) printf '%s\n' '{"state":"pending","statuses":[]}' ;;
  *"/reviews"*) printf '%s\n' '[]' ;;
  *"actions/variables/CI_RUNNER"*) printf '%s\n' '{"name":"CI_RUNNER","value":"0"}' ;;
  *) printf '%s\n' '{}' ;;
esac
STUBGH_W469
chmod +x "$tmp_cli/bin/gh_watch469"

tmp_w469="$tmp_cli/w469"
mkdir -p "$tmp_w469/bin"
ln -s "$here/lib" "$tmp_w469/lib"
cp "$GATE" "$tmp_w469/bin/pr-gate.sh"
cp "$tmp_cli/bin/gh_watch469" "$tmp_w469/bin/gh"
chmod +x "$tmp_w469/bin/pr-gate.sh" "$tmp_w469/bin/gh"

printf '0\n' >"$tmp_cli/w_drift_cnt"
drift_rc=0
drift_out="$(cd "$tmp_w469" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_W_MODE="drift" STUB_W_COUNT="$tmp_cli/w_drift_cnt" STUB_PR_INITIAL="$tmp_cli/pr_ok.json" \
  PR_GATE_POLL_INTERVAL=1 PR_GATE_HEAD_POLL_INTERVAL=1 \
  PATH="$tmp_w469/bin:$PATH" bash "$tmp_w469/bin/pr-gate.sh" 42 --repo acme/webapp --watch --format ndjson 2>&1)" || drift_rc=$?
check_rc "an earlier change CLI --watch --format ndjson HEAD_DRIFTED exits 6" "6" "$drift_rc"
if printf '%s\n' "$drift_out" | jq -e 'select(.schema == 1 and .code == "HEAD_DRIFTED" and .severity == "terminal")' >/dev/null 2>&1; then
  pass "an earlier change CLI --watch --format ndjson emits schema=1 HEAD_DRIFTED event"
else
  fail_case "an earlier change CLI --watch --format ndjson emits schema=1 HEAD_DRIFTED event" "schema=1 HEAD_DRIFTED NDJSON" "$drift_out"
fi

printf '0\n' >"$tmp_cli/w_ff_cnt"
ff_rc=0
ff_out="$(cd "$tmp_w469" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_W_MODE="failfast" STUB_W_COUNT="$tmp_cli/w_ff_cnt" STUB_PR_INITIAL="$tmp_cli/pr_ok.json" \
  PR_GATE_POLL_INTERVAL=1 \
  PATH="$tmp_w469/bin:$PATH" bash "$tmp_w469/bin/pr-gate.sh" 42 --repo acme/webapp --watch --format ndjson --fail-fast-ci=1 2>&1)" || ff_rc=$?
check_rc "an earlier change CLI --watch --fail-fast-ci=1 exits 3" "3" "$ff_rc"
if printf '%s\n' "$ff_out" | jq -e 'select(.schema == 1 and .severity == "terminal" and .code == "FIX_CI")' >/dev/null 2>&1; then
  pass "an earlier change CLI --watch --fail-fast-ci=1 emits terminal FIX_CI NDJSON"
else
  fail_case "an earlier change CLI --watch --fail-fast-ci=1 emits terminal FIX_CI NDJSON" "schema=1 terminal FIX_CI NDJSON" "$ff_out"
fi

cp "$WATCHER" "$tmp_w469/bin/auto-review-watch.sh"
chmod +x "$tmp_w469/bin/auto-review-watch.sh"
printf '0\n' >"$tmp_cli/w_ar_drift_cnt"
ar_drift_rc=0
ar_drift_out="$(cd "$tmp_w469" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  STUB_W_MODE="drift" STUB_W_COUNT="$tmp_cli/w_ar_drift_cnt" STUB_PR_INITIAL="$tmp_cli/pr_ok.json" \
  PR_GATE_POLL_INTERVAL=1 PR_GATE_HEAD_POLL_INTERVAL=1 PR_GATE_DOCKER_AVAILABLE=0 \
  PATH="$tmp_w469/bin:$PATH" bash "$tmp_w469/bin/auto-review-watch.sh" 42 --repo acme/webapp 2>&1)" || ar_drift_rc=$?
check_rc "an earlier change auto-review-watch.sh wrapper exits 2 on HEAD_DRIFTED" "2" "$ar_drift_rc"
check_prefix "an earlier change auto-review-watch.sh wrapper reports HEAD_DRIFTED" "[auto-review-watch] " "$ar_drift_out"

tmp_nm469="$tmp_cli/w469_nm"
mkdir -p "$tmp_nm469/bin"
ln -s "$here/lib" "$tmp_nm469/lib"
cp "$WATCHER" "$tmp_nm469/bin/auto-review-watch.sh"
cp "$tmp_cli/bin/gh_watch469" "$tmp_nm469/bin/gh"
cat >"$tmp_nm469/bin/pr-gate.sh" <<'STUBGATE_NM'
#!/usr/bin/env bash
printf '%s\n' '{"schema":1,"ts":"2026-11-25T22:00:00Z","repo":"acme/webapp","pr":42,"head_sha":"head1234567890","phase":"review","event":"needs_meta","severity":"terminal","code":"NEEDS_META","summary":"auto-review findings persisted across 3 commits...","gate":"4|NEEDS_META|0|persisted"}'
exit 4
STUBGATE_NM
chmod +x "$tmp_nm469/bin/auto-review-watch.sh" "$tmp_nm469/bin/gh" "$tmp_nm469/bin/pr-gate.sh"
ar_nm_rc=0
ar_nm_out="$(cd "$tmp_nm469" && PATH="$tmp_nm469/bin:$PATH" bash "$tmp_nm469/bin/auto-review-watch.sh" 42 --repo acme/webapp 2>&1)" || ar_nm_rc=$?
if [ "$ar_nm_rc" -ne 0 ]; then
  pass "an earlier change auto-review-watch.sh exits non-zero on NEEDS_META (rc=4)"
else
  fail_case "an earlier change auto-review-watch.sh exits non-zero on NEEDS_META (rc=4)" "non-zero" "$ar_nm_rc ($ar_nm_out)"
fi

# an earlier change: No auto-review docker telemetry or status --json calls during CI phase (before review)
tmp_ar_ci="$tmp_cli/w469_ar_ci"
mkdir -p "$tmp_ar_ci/bin"
ln -s "$here/lib" "$tmp_ar_ci/lib"
cp "$GATE" "$tmp_ar_ci/bin/pr-gate.sh"
cat >"$tmp_ar_ci/bin/docker" <<'STUBDOCKER_ARCI'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DOCKER_LOG"
case "$*" in
  *"inspect "*"auto-review"*)
    printf '%s\n' '{"State":{"Running":true,"Restarting":false,"Status":"running"},"RestartCount":0}'
    ;;
  *"exec "*"cat /run/auto-review/status.json"*)
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"phase":"idle","active":[],"queued":[],"harnesses":{},"tokens":[],"tick_errors":{},"recent_results":{},"last_tick_at":"%s","interval_s":180}\n' "$now_iso"
    ;;
  *"exec "*"auto-review status --json"*)
    printf '%s\n' '{"harnesses":{},"tokens":[]}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
STUBDOCKER_ARCI
cat >"$tmp_ar_ci/bin/gh" <<'STUBGH_ARCI'
#!/usr/bin/env bash
case "$*" in
  *"pr view "*)
    cat "$STUB_PR_INITIAL"
    ;;
  *"runs/10/jobs"*)
    printf '%s\n' '{"jobs":[{"id":1001,"name":"check","status":"in_progress","conclusion":null}]}'
    ;;
  *"actions/runs"*)
    cnt=0
    [ -f "$STUB_RUNS_COUNT" ] && cnt=$(cat "$STUB_RUNS_COUNT")
    cnt=$((cnt + 1))
    printf '%d\n' "$cnt" >"$STUB_RUNS_COUNT"
    if [ "$cnt" -le 2 ]; then
      printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":10,"name":"check","status":"in_progress","conclusion":null}]}'
    else
      cp -f "$STUB_DOCKER_LOG" "$STUB_DOCKER_LOG.before_review" 2>/dev/null || : >"$STUB_DOCKER_LOG.before_review"
      printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":10,"name":"check","status":"completed","conclusion":"success"}]}'
    fi
    ;;
  *"commits/"*"/status"*)
    cnt=0
    [ -f "$STUB_RUNS_COUNT" ] && cnt=$(cat "$STUB_RUNS_COUNT")
    if [ "$cnt" -le 2 ]; then
      printf '%s\n' '{"state":"pending","statuses":[]}'
    else
      printf '%s\n' '{"state":"success","statuses":[]}'
    fi
    ;;
  *"/reviews"*)
    rcnt=0
    [ -f "$STUB_REV_COUNT" ] && rcnt=$(cat "$STUB_REV_COUNT")
    rcnt=$((rcnt + 1))
    printf '%d\n' "$rcnt" >"$STUB_REV_COUNT"
    if [ "$rcnt" -eq 4 ]; then
      cp -f "$STUB_DOCKER_LOG" "$STUB_DOCKER_LOG.on_review_entry" 2>/dev/null || : >"$STUB_DOCKER_LOG.on_review_entry"
    fi
    if [ "$rcnt" -le 5 ]; then
      printf '%s\n' '[]'
    else
      printf '%s\n' '[{"commit_id":"head123","body":"**No findings.**\n\n---\n_Automated review. Not an approval._","user":{"login":"auto-review"},"state":"COMMENTED"}]'
    fi
    ;;
  *"actions/variables/CI_RUNNER"*)
    printf '%s\n' '{"name":"CI_RUNNER","value":"0"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
STUBGH_ARCI
chmod +x "$tmp_ar_ci/bin/pr-gate.sh" "$tmp_ar_ci/bin/docker" "$tmp_ar_ci/bin/gh"
: >"$tmp_ar_ci/docker.log"
printf '0\n' >"$tmp_ar_ci/runs_count"
printf '0\n' >"$tmp_ar_ci/rev_count"
ar_ci_rc=0
ar_ci_out="$(cd "$tmp_ar_ci" && AUTO_REVIEW_PROJECTS_FILE="$tmp_cli/projects.json" \
  AUTO_REVIEW_STATUS_FILE="" \
  STUB_PR_INITIAL="$tmp_cli/pr_ok.json" \
  STUB_DOCKER_LOG="$tmp_ar_ci/docker.log" \
  STUB_RUNS_COUNT="$tmp_ar_ci/runs_count" \
  STUB_REV_COUNT="$tmp_ar_ci/rev_count" \
  PR_GATE_DOCKER_AVAILABLE=1 PR_GATE_POLL_INTERVAL=1 PR_GATE_HEAD_POLL_INTERVAL=999 \
  PATH="$tmp_ar_ci/bin:$PATH" bash "$tmp_ar_ci/bin/pr-gate.sh" 42 --repo acme/webapp --watch --format ndjson 2>&1)" || ar_ci_rc=$?
check_rc "an earlier change CI->review watch with docker available exits 0" "0" "$ar_ci_rc"
if printf '%s\n' "$ar_ci_out" | jq -e 'select(.schema == 1 and .severity == "terminal" and .code == "OK")' >/dev/null 2>&1; then
  pass "an earlier change CI->review watch emits terminal OK NDJSON"
else
  fail_case "an earlier change CI->review watch emits terminal OK NDJSON" "schema=1 terminal OK NDJSON" "$ar_ci_out"
fi
before_rev_log="$(cat "$tmp_ar_ci/docker.log.before_review" 2>/dev/null || true)"
entry_rev_log="$(cat "$tmp_ar_ci/docker.log.on_review_entry" 2>/dev/null || true)"
if printf '%s\n' "$before_rev_log" "$entry_rev_log" | grep -qE 'auto-review status --json|auto-review'; then
  fail_case "an earlier change no auto-review docker calls during CI phase" "no auto-review docker calls before review" "$before_rev_log$entry_rev_log"
else
  pass "an earlier change no auto-review docker calls during CI phase"
fi
cli_status_calls="$(grep -c 'auto-review status --json' "$tmp_ar_ci/docker.log" || true)"
check "an earlier change auto-review status --json called once on entering review phase" "1" "$cli_status_calls"


printf '\nSummary: %d passed, %d failed\n' "$pass_count" "$fail_count"
exit "$fail"
