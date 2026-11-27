# Architecture & Gate Protocol

## Pure Core vs Thin I/O Shell

`pr-gate` splits network/CLI side effects from policy evaluation:

- **`bin/pr-gate.sh`** fetches PR metadata, check runs, reviews, and optional local service status, then invokes `decide_pr_gate`.
- **`lib/pr-gate-core.sh`** is a pure, zero-I/O shell library whose functions accept JSON/flags and emit deterministic `<code|STATUS|allow_admin|reason>` lines.
- **`lib/pr_gate_watch_core.py`** implements `WatchStateMachine` with adaptive polling (15s initial, 30s steady, +/-20% jitter), ETag conditional requests, rate-limit backoff, secret redaction, and `schema: 1` NDJSON event formatting.

## Decision Pipeline (`decide_pr_gate`)

1. Validate PR state (`OPEN`, non-draft, mergeable, no base merge commits unless `--base-merge-ok`).
2. Evaluate CI checks (`evaluate_ci_state`): fail fast on failed runs or return `2|WAIT_CI` while pending.
3. Evaluate automated review (`evaluate_review_state` + `lib/auto-review-mark.sh`): verify review covers current `headRefOid` and has no unresolved findings.
4. Check `no-review` label and size-refusal markers -> `5|NEEDS_OWNER` unless explicit owner approval exists.
5. Check optional PR-body contracts:
   - **`Executors` ledger block:** if the PR author matches `PR_GATE_AGENT_AUTHOR_RE`, require an `Executors` block in the PR body (`4|NEEDS_META` if missing).
   - **`hotfix` `Debt-Issue` lock:** if labeled `hotfix`, require `Debt-Issue: #<N>` in the PR body (`4|NEEDS_META` if missing).
6. Check protected paths (`touches_protected` for `.github/workflows/` and `CODEOWNERS`) -> `5|NEEDS_OWNER` unless owner-approved on `headRefOid`.
7. Check `--cross-area` flag -> `4|NEEDS_META` if set.
8. Return `0|OK`.

## Optional Integrations & Environment Variables

`pr-gate` degrades gracefully when local companion services are absent:

| Variable | Purpose |
| --- | --- |
| `PR_GATE_OWNER_LOGIN` | GitHub login whose explicit approval satisfies `NEEDS_OWNER` checks. |
| `PR_GATE_AGENT_AUTHOR_RE` | Regex identifying bot/agent PR authors subject to the `Executors` ledger check. |
| `PR_GATE_DOCKER_AVAILABLE` | Set to `0` to skip local Docker container probes for `auto-review` and `docker-ci-gate`. |
| `AUTO_REVIEW_PROJECTS_FILE` | Path to `pr-auto-review` `projects.json` registry for pickup diagnostics. |
| `PR_GATE_CI_RUNNER_STATUS_FILE` | Path to `docker-ci-gate` `status.json` for runner queue/scheduling diagnostics. |
