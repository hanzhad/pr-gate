#!/usr/bin/env bash
# PR Gate: Pure Decision Core.
# Evaluates CI state, auto-review state, CODEOWNERS, hotfix locks, and PR metadata.
# Zero external I/O (no gh, git, docker, or systemctl calls).

_PR_GATE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_PR_GATE_CORE_DIR/auto-review-mark.sh" ]; then
  # shellcheck disable=SC1091
  source "$_PR_GATE_CORE_DIR/auto-review-mark.sh"
fi

# Logins of agent accounts (a leading app/ and a trailing [bot] are stripped first).
# A pull request they open needs an Executors block.
PR_GATE_AGENT_AUTHOR_RE="${PR_GATE_AGENT_AUTHOR_RE:-^[A-Za-z0-9-]+-agent$}"

# Login of the repository owner whose approval on headRefOid releases protected gates.
PR_GATE_OWNER_LOGIN="${PR_GATE_OWNER_LOGIN:-hanzhad}"

# evaluate_ci_state <runs_json> <status_json> [pr_json]
# Returns one of:
#   unreadable:runs
#   unreadable:status
#   pending
#   failed:<name> (or comma-separated)
#   settled_green
#   settled_no_ci
evaluate_ci_state() {
  local runs_json="${1:-}"
  local status_json="${2:-}"
  local pr_json="${3:-}"

  if [ -z "$runs_json" ]; then
    echo "unreadable:runs"
    return 0
  fi
  if ! printf '%s' "$runs_json" | jq -es 'length == 1 and (.[0] | type == "object" and has("workflow_runs") and (.workflow_runs | type == "array"))' >/dev/null 2>&1; then
    echo "unreadable:runs"
    return 0
  fi

  if [ -z "$status_json" ]; then
    echo "unreadable:status"
    return 0
  fi
  if ! printf '%s' "$status_json" | jq -es 'length == 1 and (.[0] | type == "object" and (has("statuses") or has("state")))' >/dev/null 2>&1; then
    echo "unreadable:status"
    return 0
  fi

  local pr_branch="" pr_author="" pr_head=""
  if [ -n "$pr_json" ]; then
    {
      IFS= read -r pr_branch || true
      IFS= read -r pr_author || true
      IFS= read -r pr_head || true
    } < <(printf '%s' "$pr_json" | jq -r '((.headRefName // "") | gsub("[\r\n]"; "")), ((.author.login // "") | gsub("[\r\n]"; "")), ((.headRefOid // "") | gsub("[\r\n]"; ""))' 2>/dev/null || true)
  fi

  local is_cr_bot="false"
  case "$pr_branch" in
    changeset-release/*)
      if [ -n "${pr_branch#changeset-release/}" ]; then
        case "$pr_author" in
          app/github-actions | 'github-actions[bot]' | 'app/github-actions[bot]')
            is_cr_bot="true"
            ;;
        esac
      fi
      ;;
  esac

  printf '%s\n%s\n' "$runs_json" "$status_json" | jq -rs \
    --arg is_cr_bot "$is_cr_bot" \
    --arg pr_head "$pr_head" '
    (.[0].workflow_runs // []) as $wr |
    (.[1]) as $status |
    ($status.statuses // []) as $st |
    (($is_cr_bot == "true") and (
      any($wr[];
        .status == "completed" and
        .conclusion == "success" and
        $pr_head != "" and
        (.head_sha // "") == $pr_head and
        ((.event // "") == "workflow_dispatch" or ((.name // "") | ascii_downcase | (. == "verify" or . == "release verify")))
      )
      or
      any($st[];
        .state == "success" and
        ($pr_head == "" or (($status.sha // "") == "") or (($status.sha // "") == $pr_head)) and
        ((.context // "") | ascii_downcase | (. == "verify" or . == "release verify"))
      )
    )) as $waive_cr_ar |

    if (any($wr[]; .status != "completed") or any($st[]; .state == "pending")) then
      "pending"
    else
      ([$wr[] | select(
        .status == "completed" and
        (.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") and
        (($waive_cr_ar and ((.event // "") == "pull_request") and (.conclusion == "action_required")) | not)
      ) | .name] +
       [$st[] | select(.state == "failure" or .state == "error") | .context]) as $failures |
      if ($failures | length) > 0 then
        "failed:" + ($failures | join(","))
      elif ($wr | length) == 0 and ($st | length) == 0 then
        "settled_no_ci"
      else
        "settled_green"
      end
    end
  '
}

# evaluate_review_state <auto_review_installed:0|1> <head_sha> <reviews_json> <base_merge_ok:0|1>
# Returns one of:
#   not_required
#   wait_review
#   clean
#   refused_size
#   skipped_low_risk
#   findings
evaluate_review_state() {
  local auto_review_installed="${1:-0}"
  local head_sha="${2:-}"
  local reviews_json="${3:-}"
  local base_merge_ok="${4:-0}"

  if [ "$auto_review_installed" != "1" ]; then
    echo "not_required"
    return 0
  fi

  if [ -z "$reviews_json" ]; then
    echo "wait_review"
    return 0
  fi

  local auto_reviews
  auto_reviews="$(select_auto_reviews "$reviews_json")"

  local count
  count="$(printf '%s' "$auto_reviews" | jq 'length' 2>/dev/null || echo 0)"
  if [ "$count" -eq 0 ]; then
    echo "wait_review"
    return 0
  fi

  local last_review
  last_review="$(printf '%s' "$auto_reviews" | jq -c '.[-1]')"
  local commit_id
  commit_id="$(auto_review_commit_sha "$last_review")"

  local commit_matches=0
  if [ -n "$commit_id" ]; then
    if [ "$commit_id" = "$head_sha" ] || [[ "$head_sha" == "$commit_id"* ]]; then
      commit_matches=1
    fi
  fi

  if [ "$commit_matches" != "1" ] && [ "$base_merge_ok" != "1" ]; then
    echo "wait_review"
    return 0
  fi

  local body
  body="$(printf '%s' "$last_review" | jq -r '.body // ""')"
  auto_review_verdict "$body"
}

# count_auto_review_finding_rounds <reviews_json>
# Counts distinct commit SHAs that received an auto-review verdict of "findings".
# Normalizes short (>=7 hex) vs full SHAs so prefix matches count once.
count_auto_review_finding_rounds() {
  local reviews_json="${1:-}"
  if [ -z "$reviews_json" ]; then
    echo "0"
    return 0
  fi
  if ! printf '%s' "$reviews_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "0"
    return 0
  fi

  local auto_reviews
  auto_reviews="$(select_auto_reviews "$reviews_json")"

  local -a seen_shas=()
  local idx=0
  local rev body verdict sha matched i existing
  while IFS= read -r rev; do
    [ -n "$rev" ] || continue
    body="$(printf '%s' "$rev" | jq -r '.body // ""' 2>/dev/null || echo "")"
    verdict="$(auto_review_verdict "$body")"
    if [ "$verdict" != "findings" ]; then
      continue
    fi

    sha="$(auto_review_commit_sha "$rev")"
    if [ -z "$sha" ]; then
      sha="__nosha_${idx}"
      idx=$((idx + 1))
    elif [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
      sha="$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')"
    fi

    matched=0
    for i in "${!seen_shas[@]}"; do
      existing="${seen_shas[$i]}"
      if [ "$sha" = "$existing" ]; then
        matched=1
        break
      fi
      if [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] && [[ "$existing" =~ ^[0-9a-f]{7,40}$ ]]; then
        if [[ "$existing" == "$sha"* ]]; then
          matched=1
          break
        elif [[ "$sha" == "$existing"* ]]; then
          seen_shas[i]="$sha"
          matched=1
          break
        fi
      fi
    done

    if [ "$matched" -eq 0 ]; then
      seen_shas+=("$sha")
    fi
  done < <(printf '%s' "$auto_reviews" | jq -c '.[]' 2>/dev/null || true)

  echo "${#seen_shas[@]}"
}

# count_finding_rounds <reviews_json>
# Alias for count_auto_review_finding_rounds.
count_finding_rounds() {
  count_auto_review_finding_rounds "$@"
}

# extract_hotfix_debt_issue <pr_body>
# Extracts the first Debt-Issue reference (#N or owner/repo#N) from PR body.
extract_hotfix_debt_issue() {
  local body="${1:-}"
  [ -n "$body" ] || return 1

  local re='^[[:space:]]*Debt-Issue:[[:space:]]*(([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+)([[:space:]]|$)'
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    if [[ "$line" =~ $re ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<<"$body"

  return 1
}

# parse_hotfix_debt_issue_ref <debt_ref> <default_repo>
# Parses #N or owner/repo#N into "<repo>\t<issue_number>". Returns 1 on invalid/empty ref.
parse_hotfix_debt_issue_ref() {
  local debt_ref="${1:-}"
  local default_repo="${2:-}"
  [ -n "$debt_ref" ] || return 1

  local issue_repo issue_num
  case "$debt_ref" in
    */*#*)
      issue_repo="${debt_ref%%#*}"
      issue_num="${debt_ref##*#}"
      ;;
    \#*)
      issue_repo="$default_repo"
      issue_num="${debt_ref#\#}"
      ;;
    *)
      return 1
      ;;
  esac

  case "$issue_num" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -n "$issue_repo" ] || return 1
  printf '%s\t%s\n' "$issue_repo" "$issue_num"
}

# evaluate_executor_ledger <pr_json> | <is_agent:true|false> <has_block:true|false>
# Evaluates whether an agent-authored PR carries the required Executors block.
# Prints "missing" (exit 1) when missing, else "ok" (exit 0).
evaluate_executor_ledger() {
  local is_agent="false" has_block="false"
  if [ "$#" -ge 2 ]; then
    is_agent="${1:-false}"
    has_block="${2:-false}"
  else
    local pr_json="${1:-}"
    [ -n "$pr_json" ] || { echo "ok"; return 0; }
    {
      IFS= read -r is_agent || true
      IFS= read -r has_block || true
    } < <(printf '%s' "$pr_json" | jq -r --arg agent_re "$PR_GATE_AGENT_AUTHOR_RE" '
      ((.author.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "") | . != "" and test($agent_re) | tostring),
      ((.body // "") | contains("<!-- EXECUTORS:START -->") | tostring)
    ' 2>/dev/null || true)
  fi

  if [ "$is_agent" = "true" ] && [ "$has_block" != "true" ]; then
    echo "missing"
    return 1
  fi
  echo "ok"
  return 0
}

# touches_protected <files_or_pr_json> <codeowners_text>
# Prints each file path matching a CODEOWNERS rule on its own line, or a sentinel
# (<unreadable:codeowners>, <unreadable:files>, <unreadable:files-truncated>) on failure.
touches_protected() {
  local input="${1:-}"
  local codeowners="${2:-}"

  local patterns=""
  if [ -n "$codeowners" ]; then
    patterns="$(printf '%s\n' "$codeowners" | tr -d '\r' | awk '
      {
        gsub(/^[ \t]+|[ \t]+$/, "", $0)
        if ($0 == "" || substr($0, 1, 1) == "#") next
        split($0, fields, /[ \t]+/)
        if (fields[1] != "") print fields[1]
      }
    ')"
  fi
  if [ -z "$codeowners" ] || [ -z "$patterns" ]; then
    printf '%s\n' '<unreadable:codeowners>'
    return 0
  fi

  if [ -z "$input" ]; then
    printf '%s\n' '<unreadable:files>'
    return 0
  fi

  local trimmed_input files=""
  trimmed_input="${input#"${input%%[![:space:]]*}"}"
  case "$trimmed_input" in
    '{'*|'['*)
      if ! printf '%s' "$input" | jq -e 'type == "object" and (.files | type == "array") and (.files | length > 0) and all(.files[]; (type == "object") and ((.path // "") != ""))' >/dev/null 2>&1; then
        printf '%s\n' '<unreadable:files>'
        return 0
      fi
      if printf '%s' "$input" | jq -e '((.files | length) >= 100 and ((.files_complete // false) | not)) or ((.changedFiles // 0) > (.files | length))' >/dev/null 2>&1; then
        printf '%s\n' '<unreadable:files-truncated>'
        return 0
      fi
      files="$(printf '%s' "$input" | jq -r '.files[].path')"
      ;;
    *)
      if ! printf '%s\n' "$input" | awk '!found && NF { found=1 } END { exit !found }'; then
        printf '%s\n' '<unreadable:files>'
        return 0
      fi
      files="$input"
      ;;
  esac

  awk -v pats="$patterns" '
    function glob_to_ere(pat,   anchored, dir_rule, out, i, n, c, nx) {
      anchored = 0
      dir_rule = 0
      if (substr(pat, 1, 1) == "/") {
        anchored = 1
        pat = substr(pat, 2)
      }
      if (substr(pat, length(pat), 1) == "/") {
        dir_rule = 1
        pat = substr(pat, 1, length(pat) - 1)
      }
      if (pat == "") return ""
      if (index(pat, "/") > 0) anchored = 1

      out = ""
      n = length(pat)
      i = 1
      while (i <= n) {
        c = substr(pat, i, 1)
        nx = (i < n ? substr(pat, i + 1, 1) : "")
        if (c == "*" && nx == "*") {
          if (i + 2 <= n && substr(pat, i + 2, 1) == "/") {
            out = out "(.*/)?"
            i += 3
          } else {
            out = out ".*"
            i += 2
          }
          continue
        }
        if (c == "*") { out = out "[^/]*"; i++; continue }
        if (c == "?") { out = out "[^/]"; i++; continue }
        if (c ~ /[.+^$()\[\]{}|\\]/) { out = out "\\" c; i++; continue }
        out = out c
        i++
      }
      return (anchored ? "^" : "(^|.*/)") out (dir_rule ? "/.*$" : "$")
    }
    BEGIN {
      np = split(pats, raw_pats, "\n")
      nr = 0
      for (k = 1; k <= np; k++) {
        if (raw_pats[k] == "") continue
        re = glob_to_ere(raw_pats[k])
        if (re != "") {
          nr++
          res[nr] = re
        }
      }
    }
    {
      gsub(/\r/, "", $0)
      gsub(/^[ \t]+|[ \t]+$/, "", $0)
      if ($0 == "") next
      for (k = 1; k <= nr; k++) {
        if ($0 ~ res[k]) {
          print $0
          break
        }
      }
    }
  ' <<<"$files"
}

# owner_approved_head <pr_json> [owner_login]
# Returns 0 iff the last non-COMMENTED review by owner on headRefOid is APPROVED.
owner_approved_head() {
  local pr_json="${1:-}"
  local owner="${2:-$PR_GATE_OWNER_LOGIN}"
  [ -n "$pr_json" ] && [ -n "$owner" ] || return 1

  local state
  state="$(printf '%s' "$pr_json" | jq -r --arg owner "$owner" '
    (.headRefOid // "") as $head |
    if $head == "" then "" else
      [
        (.reviews // [])[]? |
        select(((.author.login // .user.login // "") == $owner) and ((.commit.oid // .commit_id // "") == $head)) |
        .state // "" |
        select(. == "APPROVED" or . == "CHANGES_REQUESTED" or . == "DISMISSED")
      ] | last // ""
    end
  ' 2>/dev/null || echo "")"

  [ "$state" = "APPROVED" ]
}

# evaluate_merge_fallback <expected_head_sha> <recheck_json>
# Evaluates re-fetched {mergeable, headRefOid} after non-admin merge fails.
# Prints <exit_code>|<STATUS>|<allow_admin>|<reason>; 0|ADMIN_MERGE|1|... permits --admin fallback.
evaluate_merge_fallback() {
  local expected_head="${1:-}"
  local recheck_json="${2:-}"

  local recheck_mergeable="" recheck_head=""
  if [ -n "$recheck_json" ]; then
    {
      IFS= read -r recheck_mergeable || true
      IFS= read -r recheck_head || true
    } < <(printf '%s' "$recheck_json" | jq -r '((.mergeable // "") | gsub("[\r\n]"; "")), ((.headRefOid // "") | gsub("[\r\n]"; ""))' 2>/dev/null || true)
  fi

  if [ "$recheck_mergeable" = "CONFLICTING" ]; then
    echo "3|FIX_CONFLICTS|0|pull request has merge conflicts"
  elif [ -z "$recheck_mergeable" ] && [ -z "$recheck_head" ]; then
    echo "1|ERROR|0|cannot verify mergeable state before admin fallback (empty)"
  elif [ -z "$expected_head" ] || [ "$recheck_head" != "$expected_head" ]; then
    echo "1|ERROR|0|pull request head changed during merge (${expected_head:-empty} -> ${recheck_head:-unknown})"
  elif [ "$recheck_mergeable" = "UNKNOWN" ]; then
    echo "2|WAIT_MERGEABLE|0|mergeability is still being computed"
  elif [ "$recheck_mergeable" != "MERGEABLE" ]; then
    echo "1|ERROR|0|cannot verify mergeable state before admin fallback (${recheck_mergeable:-empty})"
  else
    echo "0|ADMIN_MERGE|1|mergeable re-verified on head"
  fi
}

# decide_pr_gate <pr_json> <ci_state> <review_state> <cross_area:0|1> [protected_hits]
# Returns <exit_code>|<STATUS>|<allow_admin>|<reason>
decide_pr_gate() {
  local pr_json="${1:-}"
  local ci_state="${2:-}"
  local review_state="${3:-}"
  local cross_area="${4:-0}"
  local protected_hits="${5:-}"

  local protected_csv=""
  if [ -n "$protected_hits" ]; then
    protected_csv="$(printf '%s\n' "$protected_hits" | tr -d '\r' | awk '{ gsub(/^[ \t]+|[ \t]+$/, "", $0); if ($0 != "") out = (out ? out "," $0 : $0) } END { printf "%s", out }')"
  fi

  local owner_approved=0
  if owner_approved_head "$pr_json"; then
    owner_approved=1
  fi

  local pr_state="" is_draft="" mergeable="" touches_workflows="" has_no_review=""
  local changes_requested="" is_agent="" has_block="" files_status="" has_hotfix="" debt_issue_state=""
  if [ -n "$pr_json" ]; then
    {
      IFS= read -r pr_state || true
      IFS= read -r is_draft || true
      IFS= read -r mergeable || true
      IFS= read -r touches_workflows || true
      IFS= read -r has_no_review || true
      IFS= read -r changes_requested || true
      IFS= read -r is_agent || true
      IFS= read -r has_block || true
      IFS= read -r files_status || true
      IFS= read -r has_hotfix || true
      IFS= read -r debt_issue_state || true
    } < <(printf '%s' "$pr_json" | jq -r --arg agent_re "$PR_GATE_AGENT_AUTHOR_RE" '
      ((.state // "") | gsub("[\r\n]"; "")),
      (.isDraft // false | tostring),
      ((.mergeable // "") | gsub("[\r\n]"; "")),
      ([(.files // [])[]?.path // empty | select(. == ".github/workflows" or startswith(".github/workflows/"))] | length > 0 | tostring),
      ([(.labels // [])[]?.name // empty | select(. == "no-review" or contains("no-review"))] | length > 0 | tostring),
      ([(.reviews // [])[]?.state // empty | select(. == "CHANGES_REQUESTED")] | length > 0 | tostring),
      ((.author.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "") | . != "" and test($agent_re) | tostring),
      ((.body // "") | contains("<!-- EXECUTORS:START -->") | tostring),
      (
        if (((.files | type == "array") and (.files | length > 0) and all(.files[]; (type == "object") and ((.path // "") != ""))) | not) then "unreadable"
        elif ((((.files | length) >= 100 and ((.files_complete // false) | not)) or ((.changedFiles // 0) > (.files | length)))) then "truncated"
        else "ok"
        end
      ),
      ([(.labels // [])[]?.name // empty | select(ascii_downcase == "hotfix")] | length > 0 | tostring),
      ((.debt_issue_state // "") | gsub("[\r\n]"; ""))
    ' 2>/dev/null || true)
  fi

  # 1. Closed PR
  if [ "$pr_state" != "OPEN" ]; then
    echo "3|NOT_OPEN|0|pull request is not open"
    return 0
  fi

  # 2. Draft PR
  if [ "$is_draft" = "true" ]; then
    echo "3|DRAFT|0|pull request is a draft"
    return 0
  fi

  # 3. Merge conflicts
  if [ "$mergeable" = "CONFLICTING" ]; then
    echo "3|FIX_CONFLICTS|0|pull request has merge conflicts"
    return 0
  fi

  # 4. Unknown mergeability
  if [ "$mergeable" = "UNKNOWN" ]; then
    echo "2|WAIT_MERGEABLE|0|mergeability is still being computed"
    return 0
  fi

  # 5. Workflows touched
  if [ "$touches_workflows" = "true" ] && [ "$owner_approved" != "1" ]; then
    echo "5|NEEDS_OWNER|0|pull request touches .github/workflows"
    return 0
  fi

  # 5b. Fail-closed file/CODEOWNERS checks and protected paths touched
  if [ "$owner_approved" != "1" ]; then
    case "$protected_csv" in
      *"<unreadable:files-truncated>"*)
        echo "5|NEEDS_OWNER|0|pull request file list is truncated (>=100 files)"
        return 0
        ;;
    esac
    if [ "$files_status" = "truncated" ]; then
      echo "5|NEEDS_OWNER|0|pull request file list is truncated (>=100 files)"
      return 0
    fi
    case "$protected_csv" in
      *"<unreadable:files>"*)
        echo "5|NEEDS_OWNER|0|cannot read pull request changed files"
        return 0
        ;;
    esac
    if [ "$files_status" = "unreadable" ]; then
      echo "5|NEEDS_OWNER|0|cannot read pull request changed files"
      return 0
    fi
    case "$protected_csv" in
      *"<unreadable:codeowners>"*)
        echo "5|NEEDS_OWNER|0|cannot read .github/CODEOWNERS"
        return 0
        ;;
    esac
    if [ -n "$protected_csv" ]; then
      echo "5|NEEDS_OWNER|0|pull request touches protected paths ($protected_csv)"
      return 0
    fi
  fi

  # 6. no-review label
  if [ "$has_no_review" = "true" ]; then
    echo "5|NEEDS_OWNER|0|pull request carries no-review label"
    return 0
  fi

  # 7. Unreadable CI
  case "$ci_state" in
    unreadable:*)
      local sub="${ci_state#unreadable:}"
      echo "1|ERROR|0|cannot read CI ($sub)"
      return 0
      ;;
  esac

  # 8. Pending CI
  if [ "$ci_state" = "pending" ]; then
    echo "2|WAIT_CI|0|CI is still running on head"
    return 0
  fi

  # 9. Failed CI
  case "$ci_state" in
    failed:*)
      local failed_names="${ci_state#failed:}"
      echo "3|FIX_CI|0|CI failed on head ($failed_names)"
      return 0
      ;;
  esac

  # 10. Wait review
  if [ "$review_state" = "wait_review" ]; then
    echo "2|WAIT_REVIEW|0|waiting for auto-review on current head"
    return 0
  fi

  # 11. Findings / Human CHANGES_REQUESTED
  if [ "$review_state" = "findings" ] && [ "$owner_approved" != "1" ]; then
    local finding_rounds max_rounds
    finding_rounds="$(count_auto_review_finding_rounds "$(printf '%s' "$pr_json" | jq -c '.reviews // []' 2>/dev/null || echo "[]")")"
    max_rounds="${PR_GATE_MAX_FINDING_ROUNDS:-3}"
    if [ "$finding_rounds" -ge "$max_rounds" ]; then
      echo "4|NEEDS_META|0|auto-review findings persisted across ${finding_rounds} commits; stop patching and escalate to meta"
      return 0
    fi
  fi
  if [ "$review_state" = "findings" ] || [ "$changes_requested" = "true" ]; then
    echo "3|FIX_FINDINGS|0|review findings open on current head"
    return 0
  fi

  # 12. Refused size
  if [ "$review_state" = "refused_size" ] && [ "$owner_approved" != "1" ]; then
    echo "5|NEEDS_OWNER|0|auto-review refused diff size (**Not reviewed.**)"
    return 0
  fi

  # 12b. Agent pull request without an Executors block
  if ! evaluate_executor_ledger "$is_agent" "$has_block" >/dev/null; then
    echo "4|NEEDS_META|0|agent pull request is missing required Executors ledger block"
    return 0
  fi

  # 12c. Hotfix debt lock
  if [ "$has_hotfix" = "true" ] && [ "$owner_approved" != "1" ]; then
    local debt_ref
    debt_ref="$(extract_hotfix_debt_issue "$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null || echo "")" || true)"
    if [ -z "$debt_ref" ]; then
      echo "4|NEEDS_META|0|hotfix pull request requires open Debt-Issue: #<N> in body"
      return 0
    fi
    if [ -n "$debt_issue_state" ] && [ "$debt_issue_state" != "OPEN" ]; then
      echo "4|NEEDS_META|0|hotfix Debt-Issue ($debt_ref) is not open ($debt_issue_state)"
      return 0
    fi
  fi

  # 13. Skipped low risk
  if [ "$review_state" = "skipped_low_risk" ]; then
    echo "4|NEEDS_META|0|auto-review skipped low-risk paths; meta must read diff"
    return 0
  fi

  # 14. Settled no CI
  if [ "$ci_state" = "settled_no_ci" ]; then
    echo "4|NEEDS_META|0|no CI configured for commit; meta must verify diff"
    return 0
  fi

  # 15. Cross area
  if [ "$cross_area" = "1" ]; then
    echo "4|NEEDS_META|0|cross-area pull request requires meta review"
    return 0
  fi

  # 16. OK
  echo "0|OK|1|gate passed"
}
