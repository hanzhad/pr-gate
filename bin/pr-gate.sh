#!/usr/bin/env bash
# PR Gate: Thin CLI/I/O Shell.
# Pure decision cores live in lib/pr-gate-core.sh and lib/pr_gate_watch_core.py.
set -euo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  case $_self in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_PR_GATE_BIN_DIR="$(cd "$(dirname "$_self")" && pwd)"
_PR_GATE_CORE="$_PR_GATE_BIN_DIR/../lib/pr-gate-core.sh"
source "$_PR_GATE_CORE"

_PR_GATE_WATCH_CORE="$_PR_GATE_BIN_DIR/../lib/pr_gate_watch_core.py"

# The gate uid owns /var/lib/auto-review (0700) in the container.
AUTO_REVIEW_GATE_UID="${AUTO_REVIEW_GATE_UID:-10001}"
CI_RUNNER_GATE_UID="${CI_RUNNER_GATE_UID:-0}"

# ═════════════════════════════════════════════════════════════════════════════
# Thin I/O Helpers
# ═════════════════════════════════════════════════════════════════════════════

_read_auto_review_registry_json() {
  local projects_file="${AUTO_REVIEW_PROJECTS_FILE:-/var/lib/auto-review/projects.json}"
  if [ -f "$projects_file" ]; then
    cat "$projects_file" 2>/dev/null || true
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review"; then
    docker exec -u "$AUTO_REVIEW_GATE_UID" auto-review auto-review registry show 2>/dev/null || true
    return 0
  fi
  return 0
}

detect_auto_review_installed() {
  local slug="$1"
  local repo="${2:-}"
  [ -n "$repo" ] || repo="$(printf '%s' "$slug" | sed 's/-/\//')"

  local registry=""
  registry="$(_read_auto_review_registry_json)"
  if [ -n "$registry" ] && printf '%s' "$registry" | jq -e --arg r "$repo" --arg s "$slug" \
    '(.projects[$r] != null and .projects[$r].paused != true and .projects[$r].enabled != false) or (.projects[$s] != null and .projects[$s].paused != true and .projects[$s].enabled != false)' \
    >/dev/null 2>&1; then
    echo 1
    return 0
  fi
  local os
  os="$(uname -s)"
  if [ "$os" = "Darwin" ]; then
    if [ -f "$HOME/Library/LaunchAgents/com.pr-auto-review.$slug.plist" ]; then
      echo 1
      return 0
    fi
  else
    if systemctl --user is-enabled "com.pr-auto-review.$slug.timer" >/dev/null 2>&1; then
      echo 1
      return 0
    fi
    if systemctl --user list-timers "com.pr-auto-review.$slug.timer" 2>/dev/null | grep -q "com.pr-auto-review.$slug.timer"; then
      echo 1
      return 0
    fi
    if [ -f "$HOME/.config/systemd/user/com.pr-auto-review.$slug.timer" ]; then
      echo 1
      return 0
    fi
  fi
  echo 0
}

_extract_registry_project_json() {
  local registry="$1" repo="$2" slug="$3"
  if [ -z "$registry" ]; then
    printf 'null'
    return 0
  fi
  printf '%s' "$registry" | jq -c --arg r "$repo" --arg s "$slug" \
    '.projects[$r] // .projects[$s] // null' 2>/dev/null || printf 'null'
}

only_base_merges_since() {
  local repo="$1" base="$2" old="$3" new="$4"
  [ -n "$base" ] || return 1
  local commits
  commits="$(gh api "repos/$repo/compare/$old...$new" \
    -q '.commits[] | [.sha, (.parents | length), (.parents[1].sha // "")] | @tsv' 2>/dev/null)" || return 1
  [ -n "$commits" ] || return 1
  local sha nparents parent2 status
  while IFS=$'\t' read -r sha nparents parent2; do
    [ -n "$sha" ] || continue
    if [ "$nparents" != 2 ] || [ -z "$parent2" ]; then
      return 1
    fi
    status="$(gh api "repos/$repo/compare/$base...$parent2" -q '.status' 2>/dev/null)" || return 1
    case "$status" in
      identical | behind) ;;
      *) return 1 ;;
    esac
  done <<<"$commits"
  return 0
}

_fetch_reviews_json() {
  local repo="$1" pr="$2" raw=""
  raw="$(gh api --paginate --slurp "repos/$repo/pulls/$pr/reviews" 2>/dev/null | jq -c 'if type == "array" then [.[] | (if type == "array" then .[] else . end)] else [] end' 2>/dev/null || echo "")"
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -es 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1; then
    printf '%s' "$raw"
  else
    printf '[]'
  fi
}

_merge_pr_reviews() {
  local pr_json="$1" reviews_json="$2"
  if [ -n "$reviews_json" ] && printf '%s' "$reviews_json" | jq -es 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1; then
    printf '%s\n%s\n' "$pr_json" "$reviews_json" | jq -cs '.[0] + {reviews: .[1]}' 2>/dev/null || printf '%s' "$pr_json"
  else
    printf '%s' "$pr_json"
  fi
}

_fetch_pr_full() {
  local repo="$1" pr="$2" pr_json="" all_files_json="" cf_count=0
  pr_json="$(gh pr view "$pr" --repo "$repo" --json state,isDraft,mergeable,labels,files,changedFiles,reviews,headRefName,headRefOid,baseRefName,author,body 2>/dev/null || echo "")"
  [ -n "$pr_json" ] || return 1
  if printf '%s' "$pr_json" | jq -e '((.files | type == "array") and ((.files | length) >= 100 or ((.changedFiles // 0) > (.files | length))))' >/dev/null 2>&1; then
    all_files_json="$(gh api --paginate --slurp "repos/$repo/pulls/$pr/files" 2>/dev/null | jq -c 'if type == "array" then [.[] | (if type == "array" then .[] else . end) | {path: .filename}] else [] end' 2>/dev/null || echo "")"
    cf_count="$(printf '%s' "$pr_json" | jq -r '.changedFiles // 0' 2>/dev/null || echo 0)"
    if [ -n "$all_files_json" ] && printf '%s' "$all_files_json" | jq -es --argjson cf "$cf_count" 'length == 1 and (.[0] | type == "array" and length > 0 and (($cf <= 0) or (length == $cf)))' >/dev/null 2>&1; then
      pr_json="$(printf '%s\n%s\n' "$pr_json" "$all_files_json" | jq -cs '.[0] + {files: .[1], files_complete: true}' 2>/dev/null || printf '%s' "$pr_json")"
    fi
  fi
  printf '%s' "$pr_json"
}

_fetch_codeowners_text() {
  local repo="$1" base_ref="$2" codeowners_text="" repo_root=""
  if [ -n "$repo" ] && [ -n "$base_ref" ]; then
    codeowners_text="$(gh api -H "Accept: application/vnd.github.raw+json" "repos/$repo/contents/.github/CODEOWNERS?ref=$base_ref" 2>/dev/null || true)"
  fi
  if [ -z "$codeowners_text" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [ -f "$repo_root/.github/CODEOWNERS" ]; then
      codeowners_text="$(cat "$repo_root/.github/CODEOWNERS")"
    fi
  fi
  printf '%s' "$codeowners_text"
}

_enrich_hotfix_debt_state() {
  local repo="$1" pr_json="$2"
  if printf '%s' "$pr_json" | jq -e '[(.labels // [])[]?.name // empty | select(ascii_downcase == "hotfix")] | length > 0' >/dev/null 2>&1; then
    local debt_ref parsed_debt_ref issue_repo issue_num issue_state
    debt_ref="$(extract_hotfix_debt_issue "$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null || echo "")" || true)"
    if [ -n "$debt_ref" ]; then
      parsed_debt_ref="$(parse_hotfix_debt_issue_ref "$debt_ref" "$repo" || true)"
      if [ -n "$parsed_debt_ref" ]; then
        IFS=$'\t' read -r issue_repo issue_num <<<"$parsed_debt_ref"
        issue_state="$(gh issue view "$issue_num" --repo "$issue_repo" --json state --jq .state 2>/dev/null | tr -d '\r\n' || true)"
        [ -n "$issue_state" ] || issue_state="UNREADABLE"
        pr_json="$(printf '%s' "$pr_json" | jq -c --arg st "$issue_state" '.debt_issue_state = $st' 2>/dev/null || printf '%s' "$pr_json")"
      else
        pr_json="$(printf '%s' "$pr_json" | jq -c '.debt_issue_state = "UNREADABLE"' 2>/dev/null || printf '%s' "$pr_json")"
      fi
    fi
  fi
  printf '%s' "$pr_json"
}

_detect_docker_available() {
  if [ "${PR_GATE_DOCKER_AVAILABLE:-}" = "0" ]; then
    echo 0
    return 0
  fi
  if [ "${PR_GATE_DOCKER_AVAILABLE:-}" = "1" ]; then
    echo 1
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker ps -q >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

_detect_workflows_present() {
  local repo="$1" ref="$2" raw=""
  raw="$(gh api "repos/$repo/contents/.github/workflows?ref=$ref" 2>/dev/null || true)"
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e 'type == "array" and any(.[]; (.name // "" | test("\\.ya?ml$")))' >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

_fetch_ci_runner_var() {
  local repo="$1" val=""
  val="$(gh api "repos/$repo/actions/variables/CI_RUNNER" -q '.value // ""' 2>/dev/null || true)"
  if [ "$val" = "1" ]; then
    echo 1
  else
    echo 0
  fi
}

_inspect_container_safe() {
  local name="$1" out=""
  # Read ONLY .State and .RestartCount — never read environment/secret fields.
  out="$(docker inspect --format '{"State":{{json .State}},"RestartCount":{{.RestartCount}}}' "$name" 2>/dev/null || true)"
  if [ -n "$out" ] && printf '%s' "$out" | jq -e 'type == "object" and has("State")' >/dev/null 2>&1; then
    printf '%s' "$out"
  else
    printf 'null'
  fi
}

_read_container_logs_tail() {
  local name="$1"
  docker logs --tail 25 "$name" 2>&1 || true
}

_read_ci_runner_status_json() {
  local raw=""
  if [ -n "${PR_GATE_CI_RUNNER_STATUS_FILE:-}" ] && [ -f "${PR_GATE_CI_RUNNER_STATUS_FILE:-}" ]; then
    raw="$(cat "$PR_GATE_CI_RUNNER_STATUS_FILE" 2>/dev/null || true)"
  else
    raw="$(docker exec -u "$CI_RUNNER_GATE_UID" docker-ci-gate-gate cat /run/gate/status.json 2>/dev/null || true)"
  fi
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$raw"
  else
    printf 'null'
  fi
}

_read_auto_review_status_json() {
  local raw=""
  if [ -n "${AUTO_REVIEW_STATUS_FILE:-}" ] && [ -f "${AUTO_REVIEW_STATUS_FILE:-}" ]; then
    raw="$(cat "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null || true)"
  elif [ -f "/run/auto-review/status.json" ]; then
    raw="$(cat "/run/auto-review/status.json" 2>/dev/null || true)"
  elif [ -f "/run/user/1000/auto-review/status.json" ]; then
    raw="$(cat "/run/user/1000/auto-review/status.json" 2>/dev/null || true)"
  elif command -v docker >/dev/null 2>&1; then
    raw="$(docker exec -u "$AUTO_REVIEW_GATE_UID" auto-review cat /run/auto-review/status.json 2>/dev/null || true)"
  fi
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$raw"
  else
    printf 'null'
  fi
}

_read_auto_review_cli_status_json() {
  local raw=""
  if command -v docker >/dev/null 2>&1; then
    raw="$(docker exec -u "$AUTO_REVIEW_GATE_UID" auto-review auto-review status --json 2>/dev/null || true)"
  fi
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$raw"
  else
    printf 'null'
  fi
}

# Fetch a GitHub REST endpoint with If-None-Match ETag caching using pr_gate_watch_core.handle_http_response.
# Writes response body to <cache_base>.body and updates <cache_base>.etag; writes error text to <cache_base>.err on failure.
_gh_api_cached() {
  local endpoint="$1" cache_base="$2"
  local etag="" rc=0
  [ -f "$cache_base.etag" ] && etag="$(cat "$cache_base.etag" 2>/dev/null || true)"

  local hdr_args=(-i)
  if [ -n "$etag" ]; then
    hdr_args+=(-H "If-None-Match: $etag")
  fi

  : >"$cache_base.raw"
  : >"$cache_base.err"
  gh api "${hdr_args[@]}" "$endpoint" >"$cache_base.raw" 2>"$cache_base.err" || rc=$?

  PYTHONDONTWRITEBYTECODE=1 python3 - "$_PR_GATE_WATCH_CORE" "$cache_base" "$rc" <<'PY'
import importlib.util, json, pathlib, re, sys

core_path, cache_base, rc_str = sys.argv[1], sys.argv[2], sys.argv[3]
rc = int(rc_str)
spec = importlib.util.spec_from_file_location("pr_gate_watch_core", core_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

base = pathlib.Path(cache_base)
raw = base.with_suffix(".raw").read_text(encoding="utf-8", errors="replace")
err = base.with_suffix(".err").read_text(encoding="utf-8", errors="replace").strip()
cached = {}
body_path = base.with_suffix(".body")
etag_path = base.with_suffix(".etag")
if body_path.is_file():
    cached["body"] = body_path.read_text(encoding="utf-8", errors="replace")
if etag_path.is_file():
    cached["etag"] = etag_path.read_text(encoding="utf-8", errors="replace").strip()

m = re.match(r"^HTTP/\S+\s+(\d{3})[^\r\n]*\r?\n", raw)
if m:
    status_code = int(m.group(1))
    rest = raw[m.end():]
    sep = re.search(r"\r?\n\r?\n", rest)
    if sep:
        hdr_block = rest[:sep.start()]
        body = rest[sep.end():]
    else:
        hdr_block = rest
        body = ""
    headers = {}
    for ln in hdr_block.splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip()] = v.strip()
    res = mod.handle_http_response(status_code, body, headers, cached)
else:
    if rc == 0 and raw.strip():
        res = mod.handle_http_response(200, raw, {}, cached)
    else:
        res = {"ok": False, "error": err or raw.strip() or f"gh api exited with {rc}"}

if res.get("ok"):
    body_path.write_text(res.get("body") or "", encoding="utf-8")
    if res.get("etag"):
        etag_path.write_text(str(res["etag"]), encoding="utf-8")
    sys.exit(0)
else:
    base.with_suffix(".err").write_text(str(res.get("error") or err or "API error"), encoding="utf-8")
    sys.exit(1)
PY
}

_fetch_reviews_cached() {
  local repo="$1" pr="$2" cache_base="$3"
  local rc=0
  _gh_api_cached "repos/$repo/pulls/$pr/reviews?per_page=100" "$cache_base" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  # Check if multi-page Link: rel="next" header exists; if so, paginate fully.
  if grep -qiE '^link:.*rel="next"' "$cache_base.raw" 2>/dev/null; then
    local full_rev=""
    full_rev="$(_fetch_reviews_json "$repo" "$pr")"
    printf '%s' "$full_rev" >"$cache_base.body"
  else
    local norm=""
    norm="$(jq -c 'if type == "array" then [.[] | (if type == "array" then .[] else . end)] else [] end' "$cache_base.body" 2>/dev/null || echo "[]")"
    printf '%s' "$norm" >"$cache_base.body"
  fi
  return 0
}

_refresh_jobs_by_run() {
  local repo="$1" runs_file="$2" jobs_dir="$3" jobs_out="$4" now_s="$5" jobs_poll_interval="$6"
  mkdir -p "$jobs_dir"
  local needed_ids=""
  needed_ids="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$runs_file" "$jobs_dir" "$now_s" "$jobs_poll_interval" <<'PY'
import json, pathlib, sys

runs_path, jobs_dir, now_s, poll_iv = sys.argv[1], pathlib.Path(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
try:
    data = json.loads(pathlib.Path(runs_path).read_text(encoding="utf-8"))
except Exception:
    data = {}
runs = data.get("workflow_runs") or []
for r in runs:
    if not isinstance(r, dict):
        continue
    rid = r.get("id")
    if rid is None:
        continue
    status = str(r.get("status") or "")
    concl = r.get("conclusion")
    is_failed = (status == "completed") and (concl not in ("success", "skipped", "neutral", None, ""))
    is_active = status != "completed"
    if not (is_active or is_failed):
        continue
    jfile = jobs_dir / f"run_{rid}.json"
    done_marker = jobs_dir / f"run_{rid}.done"
    if is_failed and done_marker.is_file():
        continue
    if is_active and jfile.is_file():
        age = now_s - jfile.stat().st_mtime
        if age < poll_iv:
            continue
    print(f"{rid}\t{1 if status == 'completed' else 0}")
PY
)"

  local rid completed
  while IFS=$'\t' read -r rid completed; do
    [ -n "$rid" ] || continue
    local raw_jobs=""
    if raw_jobs="$(gh api "repos/$repo/actions/runs/$rid/jobs?per_page=100" 2>/dev/null)"; then
      if printf '%s' "$raw_jobs" | jq -e 'type == "object" and (.jobs | type == "array")' >/dev/null 2>&1; then
        printf '%s' "$raw_jobs" >"$jobs_dir/run_${rid}.json"
        if [ "$completed" = "1" ]; then
          : >"$jobs_dir/run_${rid}.done"
        fi
      fi
    fi
  done <<<"$needed_ids"

  PYTHONDONTWRITEBYTECODE=1 python3 - "$jobs_dir" "$jobs_out" <<'PY'
import json, pathlib, sys

jobs_dir, jobs_out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out = {}
for jf in sorted(jobs_dir.glob("run_*.json")):
    rid = jf.stem[4:]
    try:
        raw = json.loads(jf.read_text(encoding="utf-8"))
    except Exception:
        continue
    items = []
    for j in raw.get("jobs") or []:
        if not isinstance(j, dict):
            continue
        failed_step = None
        for st in j.get("steps") or []:
            if isinstance(st, dict) and st.get("conclusion") in ("failure", "timed_out"):
                failed_step = st.get("name")
                break
        entry = {
            "id": j.get("id"),
            "name": j.get("name") or "",
            "status": j.get("status") or "",
            "conclusion": j.get("conclusion"),
        }
        if failed_step:
            entry["failed_step"] = failed_step
        items.append(entry)
    out[rid] = items
jobs_out.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
PY
}

_run_watch_loop() {
  local pr="$1" repo="$2" slug="$3" do_merge="$4" cross_area="$5" base_merge_ok="$6"
  local out_format="$7" fail_fast_ci="$8" fail_fast_grace="$9" wait_all_ci="${10}"
  local review_pickup_timeout="${11}" review_queue_ceiling="${12}" ci_max_wait="${13}"

  local tmp_watch
  tmp_watch="$(mktemp -d)"
  _PR_GATE_TMP_WATCH="$tmp_watch"
  trap 'rm -rf "${_PR_GATE_TMP_WATCH:-}"' EXIT

  local poll_interval_override="${PR_GATE_POLL_INTERVAL:-}"
  local head_poll_interval="${PR_GATE_HEAD_POLL_INTERVAL:-60}"
  local jobs_poll_interval="${PR_GATE_JOBS_POLL_INTERVAL:-30}"

  local registry_raw registry_project_json auto_review_installed ci_runner docker_available
  registry_raw="$(_read_auto_review_registry_json)"
  registry_project_json="$(_extract_registry_project_json "$registry_raw" "$repo" "$slug")"
  auto_review_installed="$(detect_auto_review_installed "$slug" "$repo")"
  if [ "$registry_project_json" != "null" ]; then
    auto_review_installed="1"
  fi
  ci_runner="$(_fetch_ci_runner_var "$repo")"
  docker_available="$(_detect_docker_available)"

  local pr_json="" head_sha="" base_ref="" pr_branch="" pr_labels_json="[]"
  pr_json="$(_fetch_pr_full "$repo" "$pr" || echo "")"
  if [ -z "$pr_json" ]; then
    echo "1|ERROR|0|cannot fetch pull request #$pr"
    return 1
  fi
  head_sha="$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')"
  base_ref="$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""')"
  pr_branch="$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')"
  pr_labels_json="$(printf '%s' "$pr_json" | jq -c '[(.labels // [])[]?.name // empty]' 2>/dev/null || echo '[]')"

  local codeowners_text=""
  codeowners_text="$(_fetch_codeowners_text "$repo" "$base_ref")"
  pr_json="$(_enrich_hotfix_debt_state "$repo" "$pr_json")"
  printf '%s' "$pr_json" >"$tmp_watch/pr.json"

  local runs_cache="$tmp_watch/runs" status_cache="$tmp_watch/status" reviews_cache="$tmp_watch/reviews"
  local api_error=""
  if ! _gh_api_cached "repos/$repo/actions/runs?head_sha=$head_sha" "$runs_cache"; then
    api_error="$(cat "$runs_cache.err" 2>/dev/null || echo "actions/runs failed")"
  fi
  if [ -z "$api_error" ] && ! _gh_api_cached "repos/$repo/commits/$head_sha/status" "$status_cache"; then
    api_error="$(cat "$status_cache.err" 2>/dev/null || echo "commit status failed")"
  fi
  if [ -z "$api_error" ] && ! _fetch_reviews_cached "$repo" "$pr" "$reviews_cache"; then
    api_error="$(cat "$reviews_cache.err" 2>/dev/null || echo "reviews failed")"
  fi

  local runs_json="{}" status_json="{}" reviews_json="[]"
  [ -f "$runs_cache.body" ] && runs_json="$(cat "$runs_cache.body")"
  [ -f "$status_cache.body" ] && status_json="$(cat "$status_cache.body")"
  [ -f "$reviews_cache.body" ] && reviews_json="$(cat "$reviews_cache.body")"

  if [ "$auto_review_installed" = "1" ] && [ "$base_merge_ok" != "1" ] && [ -n "$head_sha" ] && [ -n "$base_ref" ]; then
    local last_review_commit=""
    last_review_commit="$(last_auto_review_commit_sha "$reviews_json")"
    if [ -n "$last_review_commit" ] && [ "$last_review_commit" != "$head_sha" ]; then
      if only_base_merges_since "$repo" "$base_ref" "$last_review_commit" "$head_sha"; then
        base_merge_ok=1
      fi
    fi
  fi

  local ci_state="unreadable:runs" review_state="wait_review" protected_hits="" gate_decision=""
  local workflows_present=0
  if [ -z "$api_error" ]; then
    pr_json="$(_merge_pr_reviews "$pr_json" "$reviews_json")"
    ci_state="$(evaluate_ci_state "$runs_json" "$status_json" "$pr_json")"
    review_state="$(evaluate_review_state "$auto_review_installed" "$head_sha" "$reviews_json" "$base_merge_ok")"
    protected_hits="$(touches_protected "$pr_json" "$codeowners_text")"
    gate_decision="$(decide_pr_gate "$pr_json" "$ci_state" "$review_state" "$cross_area" "$protected_hits")"
    if [ "$ci_state" = "settled_no_ci" ]; then
      workflows_present="$(_detect_workflows_present "$repo" "$head_sha")"
    fi
  fi

  # Write init config for WatchStateMachine
  PYTHONDONTWRITEBYTECODE=1 python3 - "$tmp_watch/init.json" \
    "$repo" "$pr" "$head_sha" "$fail_fast_ci" "$fail_fast_grace" "$wait_all_ci" \
    "$ci_runner" "$docker_available" "$ci_max_wait" "$review_pickup_timeout" \
    "$review_queue_ceiling" "$auto_review_installed" "$pr_branch" \
    "$workflows_present" "$base_merge_ok" "$poll_interval_override" \
    "$registry_project_json" "$pr_labels_json" <<'PY'
import json, pathlib, sys
(
    out_path, repo, pr, head_sha, ff_ci, ff_grace, wait_all,
    ci_runner, docker_avail, ci_max, rev_pickup, rev_ceil, ar_inst,
    pr_branch, wf_present, base_merge_ok, poll_ov, reg_json, lbl_json
) = sys.argv[1:20]
cfg = {
    "repo": repo,
    "pr": int(pr),
    "head_sha": head_sha,
    "fail_fast_ci": ff_ci == "1",
    "fail_fast_ci_grace_s": int(ff_grace),
    "wait_all_ci": wait_all == "1",
    "ci_runner": int(ci_runner),
    "docker_available": docker_avail == "1",
    "ci_max_wait_s": int(ci_max),
    "review_pickup_timeout_s": int(rev_pickup),
    "review_queue_ceiling_s": int(rev_ceil),
    "auto_review_installed": ar_inst == "1",
    "registry_project": json.loads(reg_json) if reg_json else None,
    "pr_branch": pr_branch,
    "pr_labels": json.loads(lbl_json) if lbl_json else [],
    "workflows_present": wf_present == "1",
    "only_base_merges": base_merge_ok == "1",
    "poll_interval_s": float(poll_ov) if poll_ov else None,
}
pathlib.Path(out_path).write_text(json.dumps(cfg), encoding="utf-8")
PY

  local last_head_poll_s
  last_head_poll_s="$(date +%s)"
  local need_ci_runner_inspect="0"
  local need_ar_cli_status="0"
  local current_phase="preflight"

  while true; do
    local now_s iso_ts
    now_s="$(date +%s)"
    iso_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '{}' >"$tmp_watch/jobs_by_run.json"
    if [ -z "$api_error" ] && [ -f "$runs_cache.body" ]; then
      _refresh_jobs_by_run "$repo" "$runs_cache.body" "$tmp_watch/jobs" "$tmp_watch/jobs_by_run.json" "$now_s" "$jobs_poll_interval"
    fi

    printf 'null' >"$tmp_watch/ci_runner_inspect.json"
    printf 'null' >"$tmp_watch/ci_runner_status.json"
    : >"$tmp_watch/ci_runner_logs.txt"
    if [ "$need_ci_runner_inspect" = "1" ] && [ "$docker_available" = "1" ]; then
      local cr_insp
      cr_insp="$(_inspect_container_safe "docker-ci-gate-gate")"
      printf '%s' "$cr_insp" >"$tmp_watch/ci_runner_inspect.json"
      if printf '%s' "$cr_insp" | jq -e '.State.Running == true' >/dev/null 2>&1; then
        _read_ci_runner_status_json >"$tmp_watch/ci_runner_status.json"
      else
        _read_container_logs_tail "docker-ci-gate-gate" >"$tmp_watch/ci_runner_logs.txt"
      fi
    fi

    printf 'null' >"$tmp_watch/ar_inspect.json"
    printf 'null' >"$tmp_watch/ar_status.json"
    : >"$tmp_watch/ar_logs.txt"
    if [ "$docker_available" = "1" ] && [ "$current_phase" = "review" ]; then
      local ar_insp ar_st_raw
      ar_insp="$(_inspect_container_safe "auto-review")"
      printf '%s' "$ar_insp" >"$tmp_watch/ar_inspect.json"
      if printf '%s' "$ar_insp" | jq -e '.State.Running == true and (.State.Restarting | not)' >/dev/null 2>&1; then
        ar_st_raw="$(_read_auto_review_status_json)"
        # Query auto-review status --json ONLY when requested by core (review entry/stale tick) or if status.json shows an error.
        local should_cli="$need_ar_cli_status"
        if [ "$should_cli" != "1" ] && [ "$ar_st_raw" != "null" ]; then
          if printf '%s' "$ar_st_raw" | jq -e '((.tick_errors // {} | length) > 0) or (((.recent_results // {}) | to_entries | any(.value.error_kind != "" and .value.error_kind != null)))' >/dev/null 2>&1; then
            should_cli="1"
          fi
        fi
        if [ "$should_cli" = "1" ]; then
          local cli_st
          cli_st="$(_read_auto_review_cli_status_json)"
          if [ "$cli_st" != "null" ]; then
            ar_st_raw="$(printf '%s\n%s\n' "$ar_st_raw" "$cli_st" | jq -cs '(if .[0] | type == "object" then .[0] else {} end) + .[1]' 2>/dev/null || printf '%s' "$ar_st_raw")"
          fi
        fi
        printf '%s' "$ar_st_raw" >"$tmp_watch/ar_status.json"
      else
        _read_container_logs_tail "auto-review" >"$tmp_watch/ar_logs.txt"
      fi
    fi

    printf '%s' "$gate_decision" >"$tmp_watch/gate_decision.txt"
    printf '%s' "$ci_state" >"$tmp_watch/ci_state.txt"
    printf '%s' "$review_state" >"$tmp_watch/review_state.txt"
    printf '%s' "$api_error" >"$tmp_watch/api_error.txt"

    local step_out
    step_out="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$_PR_GATE_WATCH_CORE" "$tmp_watch" "$now_s" "$iso_ts" "$head_sha" "$out_format" <<'PY'
import importlib.util, json, pathlib, random, sys

core_path, work_dir, now_s_str, iso_ts, head_sha, out_format = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("pr_gate_watch_core", core_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

wd = pathlib.Path(work_dir)
state_path = wd / "sm_state.json"
if state_path.is_file():
    sm = mod.WatchStateMachine.from_dict(json.loads(state_path.read_text(encoding="utf-8")))
else:
    sm = mod.WatchStateMachine(**json.loads((wd / "init.json").read_text(encoding="utf-8")))

def _load_json(name, default):
    p = wd / name
    if not p.is_file():
        return default
    raw = p.read_text(encoding="utf-8", errors="replace").strip()
    if not raw:
        return default
    try:
        return json.loads(raw)
    except Exception:
        return default

runs_obj = _load_json("runs.body", {})
runs = runs_obj.get("workflow_runs") if isinstance(runs_obj, dict) else []
if not isinstance(runs, list):
    runs = []

snapshot = {
    "head_sha": head_sha,
    "gate_decision": (wd / "gate_decision.txt").read_text(encoding="utf-8", errors="replace").strip(),
    "ci_state": (wd / "ci_state.txt").read_text(encoding="utf-8", errors="replace").strip(),
    "review_state": (wd / "review_state.txt").read_text(encoding="utf-8", errors="replace").strip(),
    "runs": runs,
    "jobs_by_run": _load_json("jobs_by_run.json", {}),
    "ci_runner_inspect": _load_json("ci_runner_inspect.json", None),
    "ci_runner_status": _load_json("ci_runner_status.json", None),
    "ci_runner_logs": (wd / "ci_runner_logs.txt").read_text(encoding="utf-8", errors="replace"),
    "auto_review_inspect": _load_json("ar_inspect.json", None),
    "auto_review_status": _load_json("ar_status.json", None),
    "auto_review_logs": (wd / "ar_logs.txt").read_text(encoding="utf-8", errors="replace"),
    "api_error": (wd / "api_error.txt").read_text(encoding="utf-8", errors="replace").strip() or None,
}

res = sm.step(float(now_s_str), snapshot, ts=iso_ts)
state_path.write_text(json.dumps(sm.to_dict()), encoding="utf-8")

for ev in res.get("events") or []:
    if out_format == "ndjson":
        print(json.dumps(ev, separators=(",", ":")), flush=True)
    else:
        print(f"[pr-gate] {ev['phase']}/{ev['severity']} ({ev['code']}): {ev['summary']}", flush=True)

sleep_s = float(res.get("next_poll_s") or 15.0)
if sm.poll_interval_s is None and not snapshot["api_error"] and sleep_s in (15.0, 30.0):
    sleep_s = mod.compute_poll_interval(sm.step_count - 1, jitter_factor=random.uniform(-0.2, 0.2))
sleep_s = max(1, int(round(sleep_s)))

ctrl = {
    "terminal": bool(res.get("terminal")),
    "exit_code": res.get("exit_code"),
    "gate_line": res.get("gate_line") or "",
    "sleep_s": sleep_s,
    "need_ci_runner_inspect": bool(res.get("need_ci_runner_inspect")),
    "need_auto_review_cli_status": bool(res.get("need_auto_review_cli_status")),
    "phase": res.get("phase") or "preflight",
}
(wd / "step_ctrl.json").write_text(json.dumps(ctrl), encoding="utf-8")
PY
)"
    [ -z "$step_out" ] || printf '%s\n' "$step_out"

    local is_terminal exit_code gate_line sleep_s
    is_terminal="$(jq -r '.terminal' "$tmp_watch/step_ctrl.json")"
    exit_code="$(jq -r '.exit_code // 1' "$tmp_watch/step_ctrl.json")"
    gate_line="$(jq -r '.gate_line // ""' "$tmp_watch/step_ctrl.json")"
    sleep_s="$(jq -r '.sleep_s // 15' "$tmp_watch/step_ctrl.json")"
    need_ci_runner_inspect="$(jq -r 'if .need_ci_runner_inspect then "1" else "0" end' "$tmp_watch/step_ctrl.json")"
    need_ar_cli_status="$(jq -r 'if .need_auto_review_cli_status then "1" else "0" end' "$tmp_watch/step_ctrl.json")"
    current_phase="$(jq -r '.phase // "preflight"' "$tmp_watch/step_ctrl.json")"

    if [ "$is_terminal" = "true" ]; then
      local _rc _st allow_admin _rsn
      IFS='|' read -r _rc _st allow_admin _rsn <<<"$gate_line"
      if [ "$do_merge" = "1" ] && [ "$exit_code" = "0" ] && [ "$allow_admin" = "1" ]; then
        if ! gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head_sha"; then
          local recheck_json fallback fb_code _fb_st _fb_adm _fb_rsn
          recheck_json="$(gh pr view "$pr" --repo "$repo" --json mergeable,headRefOid 2>/dev/null || echo "")"
          fallback="$(evaluate_merge_fallback "$head_sha" "$recheck_json")"
          IFS='|' read -r fb_code _fb_st _fb_adm _fb_rsn <<<"$fallback"
          if [ "$fb_code" = "0" ]; then
            if ! gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head_sha" --admin; then
              gate_line="1|ERROR|0|admin merge failed"
              exit_code=1
            fi
          else
            gate_line="$fallback"
            exit_code="$fb_code"
          fi
        fi
      fi
      if [ "$out_format" != "ndjson" ]; then
        echo "$gate_line"
      fi
      return "$exit_code"
    fi

    sleep "$sleep_s"

    # Poll next snapshot
    now_s="$(date +%s)"
    api_error=""
    local need_pr_refresh=0
    if [ $((now_s - last_head_poll_s)) -ge "$head_poll_interval" ] || [ "$gate_decision" = "2|WAIT_MERGEABLE|0|mergeability is still being computed" ]; then
      need_pr_refresh=1
      last_head_poll_s="$now_s"
    fi

    if [ "$need_pr_refresh" = "1" ]; then
      local refreshed_pr=""
      if refreshed_pr="$(_fetch_pr_full "$repo" "$pr")"; then
        refreshed_pr="$(_enrich_hotfix_debt_state "$repo" "$refreshed_pr")"
        local new_sha=""
        new_sha="$(printf '%s' "$refreshed_pr" | jq -r '.headRefOid // ""')"
        if [ -n "$new_sha" ] && [ "$new_sha" != "$head_sha" ]; then
          head_sha="$new_sha"
          # Immediately trigger HEAD_DRIFTED on next WatchStateMachine.step()
          continue
        fi
        pr_json="$refreshed_pr"
        printf '%s' "$pr_json" >"$tmp_watch/pr.json"
      else
        api_error="gh pr view failed"
      fi
    fi

    if [ -z "$api_error" ] && { [ "$current_phase" = "ci" ] || [ "$current_phase" = "ci_awaiting_registration" ] || [ "$current_phase" = "preflight" ]; }; then
      if ! _gh_api_cached "repos/$repo/actions/runs?head_sha=$head_sha" "$runs_cache"; then
        api_error="$(cat "$runs_cache.err" 2>/dev/null || echo "actions/runs failed")"
      fi
      if [ -z "$api_error" ] && ! _gh_api_cached "repos/$repo/commits/$head_sha/status" "$status_cache"; then
        api_error="$(cat "$status_cache.err" 2>/dev/null || echo "commit status failed")"
      fi
    fi

    if [ -z "$api_error" ]; then
      if ! _fetch_reviews_cached "$repo" "$pr" "$reviews_cache"; then
        api_error="$(cat "$reviews_cache.err" 2>/dev/null || echo "reviews failed")"
      fi
    fi

    if [ -z "$api_error" ]; then
      [ -f "$runs_cache.body" ] && runs_json="$(cat "$runs_cache.body")"
      [ -f "$status_cache.body" ] && status_json="$(cat "$status_cache.body")"
      [ -f "$reviews_cache.body" ] && reviews_json="$(cat "$reviews_cache.body")"
      local merged_pr=""
      merged_pr="$(_merge_pr_reviews "$pr_json" "$reviews_json")"
      ci_state="$(evaluate_ci_state "$runs_json" "$status_json" "$merged_pr")"
      review_state="$(evaluate_review_state "$auto_review_installed" "$head_sha" "$reviews_json" "$base_merge_ok")"
      protected_hits="$(touches_protected "$merged_pr" "$codeowners_text")"
      gate_decision="$(decide_pr_gate "$merged_pr" "$ci_state" "$review_state" "$cross_area" "$protected_hits")"
    fi
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# CLI Entry Point
# ═════════════════════════════════════════════════════════════════════════════

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pr=""
  repo=""
  do_merge=0
  cross_area=0
  base_merge_ok=0
  do_watch=0
  out_format="text"
  fail_fast_ci=0
  fail_fast_grace="${PR_GATE_FAIL_FAST_GRACE:-20}"
  wait_all_ci=0
  review_pickup_timeout="${PR_GATE_REVIEW_PICKUP_TIMEOUT:-600}"
  review_queue_ceiling="${PR_GATE_REVIEW_QUEUE_CEILING:-1800}"
  ci_max_wait="${PR_GATE_CI_MAX_WAIT:-1800}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        repo="$2"
        shift 2
        ;;
      --repo=*)
        repo="${1#--repo=}"
        shift
        ;;
      --pr)
        pr="$2"
        shift 2
        ;;
      --pr=*)
        pr="${1#--pr=}"
        shift
        ;;
      --merge)
        do_merge=1
        shift
        ;;
      --cross-area)
        cross_area=1
        shift
        ;;
      --base-merge-ok)
        base_merge_ok=1
        shift
        ;;
      --watch)
        do_watch=1
        shift
        ;;
      --format)
        out_format="$2"
        shift 2
        ;;
      --format=*)
        out_format="${1#--format=}"
        shift
        ;;
      --fail-fast-ci)
        fail_fast_ci=1
        shift
        ;;
      --fail-fast-ci=*)
        fail_fast_ci=1
        fail_fast_grace="${1#--fail-fast-ci=}"
        shift
        ;;
      --wait-all-ci)
        wait_all_ci=1
        shift
        ;;
      --review-pickup-timeout)
        review_pickup_timeout="$2"
        shift 2
        ;;
      --review-pickup-timeout=*)
        review_pickup_timeout="${1#--review-pickup-timeout=}"
        shift
        ;;
      -h|--help)
        cat <<'HELP'
Usage: pr-gate.sh [PR_NUMBER] [OPTIONS]

Deterministic pull-request merge & watch gate across GitHub Actions CI,
pr-auto-review, optional PR-body contracts, and CODEOWNERS.

Options:
  --pr PR_NUMBER                  Pull request number (or pass positionally)
  --repo OWNER/REPO               Target GitHub repository (defaults to current repo)
  --merge                         Squash-merge with --match-head-commit when gate returns 0|OK
  --cross-area                    Require maintainer diff review (4|NEEDS_META) on cross-area PRs
  --base-merge-ok                 Allow merge commits onto the base branch
  --watch                         Poll CI and review status until a terminal state
  --format text|ndjson            Watch output format (default: text)
  --fail-fast-ci[=SEC]            Stop watching early after CI failure grace period (default: 20s)
  --wait-all-ci                   Wait for all CI checks to settle even after a failure
  --review-pickup-timeout[=SEC]   Max wait for automated reviewer pickup (default: 600s)
  -h, --help                      Show this help message and exit 0

Exit Codes (<code|STATUS|allow_admin|reason>):
  0  OK              Ready to merge
  1  ERROR           Usage, GitHub API, or configuration error
  2  WAIT_*          CI or review still pending
  3  FIX_*           CI failed or unresolved review findings
  4  NEEDS_META      Requires maintainer diff inspection (or missing Executors/Debt-Issue contract)
  5  NEEDS_OWNER     Requires explicit owner approval (CODEOWNERS, workflows, no-review, size refusal)
  6  HEAD_DRIFTED    PR head SHA changed during watch
  7  BLOCKED_INFRA   Runner/review infrastructure timeout or scheduling stall

Environment Variables:
  PR_GATE_OWNER_LOGIN             Repository owner login for explicit approval checks
  PR_GATE_AGENT_AUTHOR_RE         Regex matching bot/agent PR authors for Executors ledger check
  PR_GATE_DOCKER_AVAILABLE        Set to 0 to skip local Docker container probes
  AUTO_REVIEW_PROJECTS_FILE       Path to pr-auto-review projects.json registry
  PR_GATE_CI_RUNNER_STATUS_FILE   Path to docker-ci-gate status.json file
HELP
        exit 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [ -z "$pr" ]; then
          pr="$1"
        fi
        shift
        ;;
    esac
  done

  case "$out_format" in
    text | ndjson) ;;
    *)
      echo "Unknown --format value: $out_format (expected text or ndjson)" >&2
      exit 1
      ;;
  esac

  if [ -z "$pr" ]; then
    branch="$(git branch --show-current 2>/dev/null || true)"
    if [ -n "$branch" ]; then
      pr="$(gh pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || true)"
    fi
    if [ -z "$pr" ]; then
      echo "1|ERROR|0|no pull request specified or found for current branch"
      exit 1
    fi
  fi

  if [ -z "$repo" ]; then
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    if [ -z "$repo" ]; then
      url="$(git remote get-url origin 2>/dev/null || true)"
      url="${url%.git}"
      url="${url#*github.com[:/]}"
      url="${url#https://github.com/}"
      url="${url#git@github.com:}"
      repo="$url"
    fi
  fi
  slug="$(printf '%s' "$repo" | tr '/' '-')"

  if [ "$do_watch" = "1" ]; then
    _run_watch_loop "$pr" "$repo" "$slug" "$do_merge" "$cross_area" "$base_merge_ok" \
      "$out_format" "$fail_fast_ci" "$fail_fast_grace" "$wait_all_ci" \
      "$review_pickup_timeout" "$review_queue_ceiling" "$ci_max_wait"
    exit $?
  fi

  auto_review_installed="$(detect_auto_review_installed "$slug" "$repo")"

  pr_json="$(_fetch_pr_full "$repo" "$pr" || echo "")"
  if [ -z "$pr_json" ]; then
    echo "1|ERROR|0|cannot fetch pull request #$pr"
    exit 1
  fi

  head_sha="$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')"
  base_ref="$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""')"

  runs_json="$(gh api "repos/$repo/actions/runs?head_sha=$head_sha" 2>/dev/null || echo "")"
  status_json="$(gh api "repos/$repo/commits/$head_sha/status" 2>/dev/null || echo "")"
  reviews_json="$(_fetch_reviews_json "$repo" "$pr")"
  pr_json="$(_merge_pr_reviews "$pr_json" "$reviews_json")"

  if [ "$auto_review_installed" = "1" ] && [ "$base_merge_ok" != "1" ] && [ -n "$head_sha" ] && [ -n "$base_ref" ]; then
    last_review_commit="$(last_auto_review_commit_sha "$reviews_json")"
    if [ -n "$last_review_commit" ] && [ "$last_review_commit" != "$head_sha" ]; then
      if only_base_merges_since "$repo" "$base_ref" "$last_review_commit" "$head_sha"; then
        base_merge_ok=1
      fi
    fi
  fi

  ci_state="$(evaluate_ci_state "$runs_json" "$status_json" "$pr_json")"
  review_state="$(evaluate_review_state "$auto_review_installed" "$head_sha" "$reviews_json" "$base_merge_ok")"

  codeowners_text="$(_fetch_codeowners_text "$repo" "$base_ref")"
  protected_hits="$(touches_protected "$pr_json" "$codeowners_text")"
  pr_json="$(_enrich_hotfix_debt_state "$repo" "$pr_json")"

  decision="$(decide_pr_gate "$pr_json" "$ci_state" "$review_state" "$cross_area" "$protected_hits")"

  IFS='|' read -r exit_code status allow_admin _reason <<<"$decision"

  if [ "$do_merge" = "1" ] && [ "$exit_code" = "0" ] && [ "$allow_admin" = "1" ]; then
    if ! gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head_sha"; then
      recheck_json="$(gh pr view "$pr" --repo "$repo" --json mergeable,headRefOid 2>/dev/null || echo "")"
      fallback="$(evaluate_merge_fallback "$head_sha" "$recheck_json")"
      IFS='|' read -r fb_code _fb_status _fb_admin _fb_reason <<<"$fallback"
      if [ "$fb_code" = "0" ]; then
        if ! gh pr merge "$pr" --repo "$repo" --squash --match-head-commit "$head_sha" --admin; then
          decision="1|ERROR|0|admin merge failed"
          exit_code=1
        fi
      else
        decision="$fallback"
        exit_code="$fb_code"
      fi
    fi
  fi

  echo "$decision"
  exit "$exit_code"
fi
