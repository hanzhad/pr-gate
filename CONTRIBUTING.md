# Contributing

- Tests first: write a failing test, then make it pass.
- One behaviour per pull request, so each change can be reviewed and reverted cleanly.
- Run the full test suite and the public-safety scan before pushing:

  ```bash
  python3 -m unittest discover -s tests -v
  bash tests/test-pr-gate.sh
  python3 scripts/scan.py --tree .
  python3 scripts/scan.py --history
  ```

- If you keep a local deny list of private terms, pass `--deny-file` or set `SCAN_DENY_FILE`.
- Use a GitHub no-reply email address for commits.
