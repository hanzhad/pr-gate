# pr-gate

Deterministic pull-request merge & watch gate across GitHub Actions CI, `pr-auto-review`, `Executors` ledger locks, `hotfix` `Debt-Issue` locks, and `CODEOWNERS`.

## Layout

- `bin/pr-gate.sh` — CLI & thin GitHub I/O shell (`--watch`, `--format text|ndjson`, `--fail-fast-ci`, `--wait-all-ci`, `--merge`)
- `bin/auto-review-watch.sh` — compatibility wrapper delegating to `bin/pr-gate.sh --watch`
- `lib/pr-gate-core.sh` — zero-I/O decision core (`evaluate_ci_state`, `evaluate_review_state`, `touches_protected`, `decide_pr_gate`)
- `lib/pr_gate_watch_core.py` — streaming watch state machine & ETag/rate-limit handler
- `lib/auto-review-mark.sh` — structured review verdict parser

## Exit Codes (`<exit_code>|<STATUS>|<allow_admin>|<reason>`)

- `0|OK` — ready to merge
- `2|WAIT_*` — CI or review still pending
- `3|FIX_*` — CI failed or unresolved review findings
- `4|NEEDS_META` — requires Meta diff inspection (e.g., `no-review` or skipped review without `allow_admin`)
- `5|NEEDS_OWNER` — requires explicit owner approval (`CODEOWNERS`, `.github/workflows/`, `no-review`, or review refused by size)
- `6|HEAD_DRIFTED` — PR head SHA changed
- `7|BLOCKED_INFRA` — infrastructure timeout or GitHub API failure

## Tests

```bash
python3 -m unittest discover -s tests -v
bash tests/test-pr-gate.sh
```
