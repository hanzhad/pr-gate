# Agent Rules (hanzhad/pr-gate)

- **Workflow:** `direct-pr` — work on a feature branch in a leased slot, open a PR with full context, wait for CI (`test` + `scan`) and `auto-review`, and merge via `pr-gate`.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`).
- **Public safety:** Every change must pass `python3 scripts/scan.py --tree .` and `--history`. Never commit tokens, credentials, personal emails, private repo references, or host-specific home paths.
- **Dependencies:** Prefer Python 3 standard library / minimal dependencies; keep runtime portable across Linux and macOS.
