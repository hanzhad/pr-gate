# Agent Rules (hanzhad/pr-gate)

- **Workflow:** Work on a feature branch, open a pull request with full context, and ensure CI (`test` + `scan`) passes before merging.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`).
- **Public safety:** Every change must pass `python3 scripts/scan.py --tree .` and `python3 scripts/scan.py --history`. Never commit tokens, credentials, personal emails, private repo references, or host-specific home paths.
- **Dependencies:** Prefer Python 3 standard library and POSIX/Bash + `jq` + `gh`; keep core decision logic zero-I/O and testable offline.
