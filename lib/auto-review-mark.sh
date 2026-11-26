#!/usr/bin/env bash
# Shared pure parsers for auto-review marks, verdicts, and review filtering.
# Zero external I/O (no gh, git, docker, or systemctl calls).

_AUTO_REVIEW_LEGACY_MARKER="Automated review. Not an approval."

# auto_review_first_line <body>
# Prints the first non-empty line of a review body (CR-stripped).
auto_review_first_line() {
  local body="${1:-}"
  printf '%s\n' "$body" | awk '!found { gsub(/\r/, "", $0); if (NF) { print; found = 1 } }'
}

# auto_review_commit_sha <review_json>
# Prints commit SHA from .commit_id, .commit.oid, embedded auto-review JSON, or footer.
auto_review_commit_sha() {
  local review_json="${1:-}"
  [ -n "$review_json" ] || return 0

  local commit_id=""
  commit_id="$(printf '%s' "$review_json" | jq -r '.commit_id // .commit.oid // ""' 2>/dev/null || echo "")"
  if [ "$commit_id" = "null" ]; then
    commit_id=""
  fi

  if [ -z "$commit_id" ]; then
    local body=""
    body="$(printf '%s' "$review_json" | jq -r '.body // ""' 2>/dev/null || echo "")"
    commit_id="$(printf '%s\n' "$body" | sed -n 's/.*<!--[[:space:]]*auto-review:[[:space:]]*.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | awk 'NR == 1 { print }')"
    if [ -z "$commit_id" ]; then
      commit_id="$(printf '%s\n' "$body" | sed -n 's/.*• Commit:[[:space:]]*\([A-Za-z0-9]\{7,40\}\).*/\1/p' | awk 'NR == 1 { print }')"
    fi
  fi

  if [ -n "$commit_id" ]; then
    printf '%s\n' "$commit_id"
  fi
}

# auto_review_verdict <body>
# Classifies an auto-review body by its first non-empty line:
#   clean | refused_size | skipped_low_risk | findings
auto_review_verdict() {
  local body="${1:-}"
  local verdict
  verdict="$(auto_review_first_line "$body")"

  case "$verdict" in
    '**No findings.'* | '**Skipped — generated files only.'*)
      echo "clean"
      ;;
    '**Not reviewed.'*)
      echo "refused_size"
      ;;
    '**Skipped — low-risk paths only.'*)
      echo "skipped_low_risk"
      ;;
    *)
      echo "findings"
      ;;
  esac
}

# select_auto_reviews <reviews_json>
# Filters a JSON array of reviews down to automated reviews, preserving order.
select_auto_reviews() {
  local reviews_json="${1:-[]}"
  [ -n "$reviews_json" ] || { printf '[]\n'; return 0; }
  printf '%s' "$reviews_json" | jq -c \
    --arg marker "$_AUTO_REVIEW_LEGACY_MARKER" \
    '[.[]? | select(.body and ((.body | contains("<!-- auto-review:")) or (.body | contains($marker))))]' \
    2>/dev/null || printf '[]\n'
}

# last_auto_review_commit_sha <reviews_json>
# Prints the commit SHA of the latest automated review in a reviews array.
last_auto_review_commit_sha() {
  local reviews_json="${1:-[]}"
  local auto_reviews last_review
  auto_reviews="$(select_auto_reviews "$reviews_json")"
  last_review="$(printf '%s' "$auto_reviews" | jq -c '.[-1] // empty' 2>/dev/null || true)"
  [ -n "$last_review" ] || return 0
  auto_review_commit_sha "$last_review"
}

# filter_auto_reviews <reviews_json> <head_sha>
# Prints the latest automated review matching head_sha (compact JSON) or empty string.
filter_auto_reviews() {
  local reviews_json="${1:-[]}"
  local head_sha="${2:-}"
  [ -n "$head_sha" ] || return 0
  [ -n "$reviews_json" ] || return 0

  local short_sha="${head_sha:0:7}"
  printf '%s' "$reviews_json" | jq -c \
    --arg head_sha "$head_sha" \
    --arg short_sha "$short_sha" \
    --arg marker "$_AUTO_REVIEW_LEGACY_MARKER" \
    '[.[]? |
      select(.body and ((.body | contains("<!-- auto-review:")) or (.body | contains($marker)))) |
      select(
        ((.commit_id // .commit.oid // "") as $cid | ($cid != "" and ($cid == $head_sha or (($cid | length) >= 7 and ($head_sha | startswith($cid))) or (($head_sha | length) >= 7 and ($cid | startswith($head_sha)))))) or
        ((.body // "") | contains("• Commit: " + $short_sha)) or
        ((.body // "") | contains("\"sha\":\"" + $head_sha + "\"")) or
        ((.body // "") | contains("\"sha\":\"" + $short_sha + "\""))
      )
    ] | last // empty' 2>/dev/null || echo ""
}
