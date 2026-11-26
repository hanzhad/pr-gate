#!/usr/bin/env bash
# auto-review-watch: Thin compatibility wrapper delegating to pr-gate.sh --watch.
# Streams terse milestone transitions to stdout and translates gate outcomes to legacy exit codes:
#   0 - Clean review (clean or skipped_low_risk)
#   1 - Review with findings, refused_size, or CI failure
#   2 - Timeout, daemon/infra error, head drift, or CLI error
set -euo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  case $_self in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_AR_WATCH_DIR="$(cd "$(dirname "$_self")" && pwd)"
_AR_WATCH_MARK="$_AR_WATCH_DIR/../lib/auto-review-mark.sh"
source "$_AR_WATCH_MARK"

# The gate uid owns /run/auto-review (0700) in the container.
AUTO_REVIEW_GATE_UID="${AUTO_REVIEW_GATE_UID:-10001}"

usage() {
  cat <<'EOF'
Usage: auto-review-watch [PR_NUMBER] [options]

Options:
  --repo <owner/repo>   Target repository (default: detected from git origin)
  --timeout <seconds>   Maximum review pickup wait time in seconds (default: 600 = 10m)
  --help                Show this message
EOF
  exit 0
}

fetch_auto_review() {
  local reviews_json
  reviews_json="$(gh api --paginate --slurp "repos/$repo/pulls/$pr/reviews" 2>/dev/null | jq -c 'if type == "array" then [.[] | (if type == "array" then .[] else . end)] else [] end' 2>/dev/null || echo "[]")"
  filter_auto_reviews "$reviews_json" "$head_sha"
}

extract_findings() {
  local body="$1"
  # Extract lines like `file/path:line` or lines matching finding citations
  printf '%s\n' "$body" | awk 'n < 5 && /^[0-9]+\.[ \t]*`[^`]+`/ { sub(/^[0-9]+\.[ \t]*/, "- "); print; n++ }'
}

_report_review_and_exit() {
  local review_json="$1"
  local label="$2"
  local body headline verdict findings
  body="$(printf '%s' "$review_json" | jq -r '.body // ""')"
  headline="$(auto_review_first_line "$body")"
  verdict="$(auto_review_verdict "$body")"
  echo "[auto-review-watch] ${label}: ${headline}"
  case "$verdict" in
    clean | skipped_low_risk)
      exit 0
      ;;
    *)
      findings="$(extract_findings "$body")"
      [ -z "$findings" ] || echo "$findings"
      exit 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  pr=""
  repo=""
  timeout=600

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
      --timeout)
        timeout="$2"
        shift 2
        ;;
      --timeout=*)
        timeout="${1#--timeout=}"
        shift
        ;;
      --help|-h)
        usage
        ;;
      *)
        if [ -z "$pr" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
          pr="$1"
          shift
        else
          echo "Unknown argument: $1" >&2
          usage
        fi
        ;;
    esac
  done

  if [ -z "$repo" ]; then
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      origin="$(git remote get-url origin 2>/dev/null || true)"
      if [ -n "$origin" ]; then
        repo="$(printf '%s\n' "$origin" | sed -E 's/^(https:\/\/|git@)github\.com[:\/]//; s/\.git$//')"
      fi
    fi
  fi
  [ -n "$repo" ] || { echo "error: cannot detect repository; pass --repo <owner/repo>" >&2; exit 2; }

  if [ -z "$pr" ]; then
    pr="$(gh pr view --repo "$repo" --json number -q .number 2>/dev/null || echo "")"
  fi
  [ -n "$pr" ] || { echo "error: cannot detect PR number; pass PR_NUMBER argument" >&2; exit 2; }

  pr_gate_bin="$_AR_WATCH_DIR/pr-gate.sh"
  [ -f "$pr_gate_bin" ] || { echo "error: cannot locate pr-gate.sh" >&2; exit 2; }

  tmp_fifo="$(mktemp -u)"
  mkfifo "$tmp_fifo"
  trap 'rm -f "$tmp_fifo"' EXIT

  bash "$pr_gate_bin" "$pr" --repo "$repo" --watch --format ndjson --review-pickup-timeout "$timeout" >"$tmp_fifo" &
  gate_pid=$!

  terminal_code=""
  terminal_event=""
  terminal_summary=""
  terminal_gate=""
  terminal_sha=""

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! printf '%s' "$line" | jq -e 'type == "object" and .schema == 1' >/dev/null 2>&1; then
      echo "$line"
      continue
    fi
    IFS=$'\t' read -r ev_sev ev_code ev_name ev_sha ev_sum ev_gate <<<"$(
      printf '%s' "$line" | jq -r '[
        (.severity // ""),
        (.code // ""),
        (.event // ""),
        (.head_sha // ""),
        (.summary // ""),
        (.gate // "")
      ] | @tsv'
    )"
    case "$ev_sev" in
      info | advisory)
        echo "[auto-review-watch] ${ev_sum}"
        ;;
      terminal)
        terminal_code="$ev_code"
        terminal_event="$ev_name"
        terminal_summary="$ev_sum"
        terminal_gate="$ev_gate"
        terminal_sha="$ev_sha"
        ;;
    esac
  done <"$tmp_fifo"

  gate_rc=0
  wait "$gate_pid" || gate_rc=$?

  head_sha="$terminal_sha"
  short_sha="${head_sha:0:7}"

  case "$gate_rc" in
    0)
      echo "[auto-review-watch] #${pr} (${short_sha}): ${terminal_summary:-Clean}"
      exit 0
      ;;
    3)
      if [ "$terminal_code" = "FIX_FINDINGS" ] && [ -n "$head_sha" ]; then
        existing_review="$(fetch_auto_review || true)"
        if [ -n "$existing_review" ]; then
          _report_review_and_exit "$existing_review" "#${pr} (${short_sha})"
        fi
      fi
      echo "[auto-review-watch] #${pr} (${short_sha}): ${terminal_summary:-$terminal_code}"
      exit 1
      ;;
    4)
      if [ "$terminal_event" = "ci_registration_timed_out" ]; then
        echo "[auto-review-watch] ${terminal_summary}"
        exit 2
      fi
      if [ -n "$head_sha" ]; then
        existing_review="$(fetch_auto_review || true)"
        if [ -n "$existing_review" ]; then
          _report_review_and_exit "$existing_review" "#${pr} (${short_sha})"
        fi
      fi
      echo "[auto-review-watch] #${pr} (${short_sha}): ${terminal_summary:-$terminal_code}"
      exit 1
      ;;
    5)
      if [ -n "$head_sha" ]; then
        existing_review="$(fetch_auto_review || true)"
        if [ -n "$existing_review" ]; then
          _report_review_and_exit "$existing_review" "#${pr} (${short_sha})"
        fi
      fi
      echo "[auto-review-watch] #${pr} (${short_sha}): ${terminal_summary:-$terminal_code}"
      exit 1
      ;;
    *)
      echo "[auto-review-watch] ${terminal_code:-ERROR}: ${terminal_summary:-$terminal_gate}"
      exit 2
      ;;
  esac
fi
