"""Pure watch state machine for pr-gate.sh --watch.

Zero subprocesses, zero network/filesystem I/O, Python 3.10+ stdlib only.
All external interactions (gh, git, docker, sleeps) live in the thin I/O shell
(bin/pr-gate.sh).
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import datetime
import fnmatch
import re
from typing import Any, Iterable, Mapping

_GATE_LINE_RE = re.compile(r"^([0-9]+)\|([A-Z_]+)\|([01])\|(.*)$")

_SECRET_PATTERNS = (
    re.compile(r"gh[pousr]_[A-Za-z0-9_]+"),
    re.compile(r"github_pat_[A-Za-z0-9_]+"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]+"),
    re.compile(r"ya29\.[A-Za-z0-9._-]+"),
)
_BEARER_PATTERN = re.compile(r"([Bb]earer)\s+[^\s\"']+")

_PREFLIGHT_FAIL_FAST_STATUSES = frozenset(
    {
        "NOT_OPEN",
        "DRAFT",
        "FIX_CONFLICTS",
        "NEEDS_OWNER",
        "FIX_CI",
        "FIX_FINDINGS",
        "OK",
        "ERROR",
    }
)

_PASSED_CONCLUSIONS = frozenset({"success", "skipped", "neutral"})

_NON_RETRYABLE_ERROR_KINDS = frozenset(
    {
        "token_invalid",
        "github_rejected",
        "stale_head",
        "worktree_scrub_failed",
        "text_holds_token",
        "harness_fault",
        "missing_token",
        "short_token",
    }
)

_RETRYABLE_ERROR_KINDS = frozenset(
    {
        "network",
        "rate_limit",
        "memory_floor",
        "post_failed",
        "worker_crash",
        "github_transient",
        "aborted",
        "list_failed",
    }
)

_BACKOFF_SCHEDULE_S = (5, 10, 20, 30)


def scrub_secrets(text: str | None, extra_secrets: Iterable[str] | None = None) -> str:
    """Redact known token shapes and held secret values from diagnostic text."""
    if not text:
        return ""
    out = str(text)
    if extra_secrets:
        for secret in extra_secrets:
            if isinstance(secret, str) and len(secret) >= 8:
                out = out.replace(secret, "[REDACTED]")
    for pat in _SECRET_PATTERNS:
        out = pat.sub("[REDACTED]", out)
    out = _BEARER_PATTERN.sub(r"\1 [REDACTED]", out)
    return out


def build_ndjson_event(
    *,
    ts: str,
    repo: str,
    pr: int,
    head_sha: str,
    phase: str,
    event: str,
    severity: str,
    code: str,
    summary: str,
    diagnostic: dict[str, Any] | None = None,
    gate: str | None = None,
) -> dict[str, Any]:
    """Construct a schema-1 NDJSON event object."""
    if severity not in ("info", "advisory", "terminal"):
        raise ValueError(f"invalid NDJSON severity: {severity!r}")
    obj: dict[str, Any] = {
        "schema": 1,
        "ts": ts,
        "repo": repo,
        "pr": int(pr),
        "head_sha": head_sha,
        "phase": phase,
        "event": event,
        "severity": severity,
        "code": code,
        "summary": summary,
    }
    if diagnostic is not None:
        obj["diagnostic"] = diagnostic
    if gate is not None and gate != "":
        obj["gate"] = gate
    return obj


def compute_poll_interval(
    poll_count: float,
    *,
    jitter_factor: float = 0.0,
    initial_s: float = 15.0,
    steady_s: float = 30.0,
) -> float:
    """Compute adaptive 15s -> 30s polling interval with +/-20% jitter."""
    base = float(initial_s) if poll_count <= 0 else float(steady_s)
    clamped = max(-0.2, min(0.2, float(jitter_factor)))
    return round(base * (1.0 + clamped), 6)


def build_etag_headers(etag: str | None) -> dict[str, str]:
    """Build conditional If-None-Match header dict when an ETag is cached."""
    if isinstance(etag, str):
        cleaned = etag.strip()
        if cleaned:
            return {"If-None-Match": cleaned}
    return {}


def handle_http_response(
    status_code: int,
    body: str,
    headers: Mapping[str, str] | None,
    cached: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Normalize HTTP 2xx / 304 Not Modified / error responses with ETag caching."""
    norm_headers = {str(k).lower(): str(v) for k, v in (headers or {}).items()}
    cached_body = str((cached or {}).get("body") or "")
    cached_etag = (cached or {}).get("etag")
    resp_etag = norm_headers.get("etag") or cached_etag

    if status_code == 304:
        return {
            "ok": True,
            "status_code": 304,
            "not_modified": True,
            "body": cached_body,
            "etag": resp_etag,
            "error": None,
        }
    if 200 <= status_code < 300:
        return {
            "ok": True,
            "status_code": status_code,
            "not_modified": False,
            "body": body,
            "etag": resp_etag,
            "error": None,
        }
    return {
        "ok": False,
        "status_code": status_code,
        "not_modified": False,
        "body": body,
        "etag": cached_etag,
        "error": f"HTTP {status_code}",
    }


def _parse_gate_line(gate_line: str) -> tuple[int, str, bool, str]:
    m = _GATE_LINE_RE.match((gate_line or "").strip())
    if not m:
        return 1, "ERROR", False, (gate_line or "unparseable gate line").strip()
    return int(m.group(1)), m.group(2), m.group(3) == "1", m.group(4).strip()


def _format_ts(now_s: float, ts: str | None) -> str:
    if ts:
        return ts
    if now_s >= 1_000_000_000:
        dt = datetime.datetime.fromtimestamp(now_s, tz=datetime.timezone.utc)
    else:
        dt = datetime.datetime(2026, 11, 25, 0, 0, 0, tzinfo=datetime.timezone.utc) + datetime.timedelta(
            seconds=float(now_s)
        )
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_timestamp_epoch(raw: Any) -> float | None:
    if raw is None or isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return None
        try:
            return float(text)
        except ValueError:
            pass
        try:
            iso = text[:-1] + "+00:00" if text.endswith("Z") else text
            dt = datetime.datetime.fromisoformat(iso)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return dt.timestamp()
        except ValueError:
            return None
    return None


def _normalize_labels(raw_labels: Any) -> list[str]:
    if not isinstance(raw_labels, list):
        return []
    out: list[str] = []
    for item in raw_labels:
        if isinstance(item, str) and item:
            out.append(item)
        elif isinstance(item, dict) and isinstance(item.get("name"), str) and item["name"]:
            out.append(item["name"])
    return out


def _as_str_list(val: Any) -> list[str]:
    if isinstance(val, str) and val:
        return [val]
    if isinstance(val, list):
        return [str(x) for x in val if isinstance(x, str) and x]
    return []


def _matches_any_glob(value: str, patterns: list[str]) -> str | None:
    if not value:
        return None
    for pat in patterns:
        if fnmatch.fnmatchcase(value, pat):
            return pat
    return None


def _sha_matches(candidate: str | None, head_sha: str) -> bool:
    if not candidate:
        return True
    if candidate == head_sha:
        return True
    if len(candidate) >= 7 and head_sha.startswith(candidate):
        return True
    if len(head_sha) >= 7 and candidate.startswith(head_sha):
        return True
    return False


def _tail_lines(text: str, max_lines: int = 25, max_chars: int = 2000) -> str:
    if not text:
        return ""
    lines = text.splitlines()[-max_lines:]
    joined = "\n".join(lines)
    if len(joined) > max_chars:
        joined = joined[-max_chars:]
    return joined


def _classify_jobs(
    runs: list[dict[str, Any]],
    jobs_by_run: Mapping[Any, list[dict[str, Any]]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    failed: list[dict[str, Any]] = []
    pending: list[dict[str, Any]] = []
    passed: list[dict[str, Any]] = []

    jobs_norm: dict[str, list[dict[str, Any]]] = {}
    for k, v in (jobs_by_run or {}).items():
        if isinstance(v, list):
            jobs_norm[str(k)] = [j for j in v if isinstance(j, dict)]

    seen_run_ids: set[str] = set()
    for run in runs or []:
        if not isinstance(run, dict):
            continue
        rid = run.get("id")
        rid_str = str(rid) if rid is not None else ""
        if rid_str:
            seen_run_ids.add(rid_str)
        r_jobs = jobs_norm.get(rid_str, [])
        if r_jobs:
            for job in r_jobs:
                status = str(job.get("status") or "")
                concl = job.get("conclusion")
                entry: dict[str, Any] = {
                    "id": job.get("id"),
                    "run_id": rid,
                    "name": job.get("name") or run.get("name") or "",
                    "status": status,
                }
                if concl is not None:
                    entry["conclusion"] = concl
                if job.get("failed_step"):
                    entry["failed_step"] = job.get("failed_step")
                if status != "completed":
                    pending.append(entry)
                elif concl in _PASSED_CONCLUSIONS:
                    passed.append(entry)
                else:
                    failed.append(entry)
        else:
            status = str(run.get("status") or "")
            concl = run.get("conclusion")
            entry = {
                "id": f"run:{rid_str}" if rid_str else run.get("name"),
                "run_id": rid,
                "name": run.get("name") or "",
                "status": status,
            }
            if concl is not None:
                entry["conclusion"] = concl
            if status != "completed":
                pending.append(entry)
            elif concl in _PASSED_CONCLUSIONS:
                passed.append(entry)
            else:
                failed.append(entry)

    for rid_str, r_jobs in jobs_norm.items():
        if rid_str in seen_run_ids:
            continue
        for job in r_jobs:
            status = str(job.get("status") or "")
            concl = job.get("conclusion")
            entry = {
                "id": job.get("id"),
                "run_id": rid_str,
                "name": job.get("name") or "",
                "status": status,
            }
            if concl is not None:
                entry["conclusion"] = concl
            if job.get("failed_step"):
                entry["failed_step"] = job.get("failed_step")
            if status != "completed":
                pending.append(entry)
            elif concl in _PASSED_CONCLUSIONS:
                passed.append(entry)
            else:
                failed.append(entry)

    return failed, pending, passed


def _container_down_info(inspect_obj: Mapping[str, Any] | None) -> tuple[bool, dict[str, Any]]:
    if not isinstance(inspect_obj, Mapping):
        return False, {}
    state = inspect_obj.get("State")
    if not isinstance(state, Mapping):
        state = {}
    status = str(state.get("Status") or "").lower()
    running = state.get("Running")
    restarting = bool(state.get("Restarting"))
    restart_count = inspect_obj.get("RestartCount", 0)
    is_down = (running is False) or restarting or (status not in ("", "running"))
    info = {
        "state": dict(state),
        "restart_count": restart_count,
    }
    return is_down, info


def _is_retryable_error(error_kind: str, retryable_raw: Any) -> bool:
    if isinstance(retryable_raw, bool):
        return retryable_raw
    ek = (error_kind or "").strip().lower()
    if ek in _NON_RETRYABLE_ERROR_KINDS:
        return False
    if ek in _RETRYABLE_ERROR_KINDS:
        return True
    return False


class WatchStateMachine:
    """Pure state machine governing pr-gate --watch transitions and diagnostics."""

    def __init__(
        self,
        *,
        repo: str,
        pr: int,
        head_sha: str,
        fail_fast_ci: bool = False,
        fail_fast_ci_grace_s: int = 20,
        wait_all_ci: bool = False,
        ci_runner: int = 0,
        docker_available: bool = True,
        ci_max_wait_s: int = 1800,
        review_pickup_timeout_s: int = 600,
        review_queue_ceiling_s: int = 1800,
        auto_review_installed: bool = True,
        registry_project: dict[str, Any] | None = None,
        pr_branch: str = "",
        pr_labels: list[Any] | None = None,
        workflows_present: bool = False,
        only_base_merges: bool = False,
        poll_interval_s: float | None = None,
    ) -> None:
        self.repo = repo
        self.pr = int(pr)
        self.head_sha = head_sha
        self.fail_fast_ci = bool(fail_fast_ci) and not bool(wait_all_ci)
        self.fail_fast_ci_grace_s = int(fail_fast_ci_grace_s)
        self.wait_all_ci = bool(wait_all_ci)
        self.ci_runner = int(ci_runner) if ci_runner is not None else 0
        self.docker_available = bool(docker_available)
        self.ci_max_wait_s = int(ci_max_wait_s)
        self.review_pickup_timeout_s = int(review_pickup_timeout_s)
        self.review_queue_ceiling_s = int(review_queue_ceiling_s)
        self.auto_review_installed = bool(auto_review_installed)
        self.registry_project = dict(registry_project) if isinstance(registry_project, Mapping) else None
        self.pr_branch = pr_branch or ""
        self.pr_labels = _normalize_labels(pr_labels)
        self.workflows_present = bool(workflows_present)
        self.only_base_merges = bool(only_base_merges)
        self.poll_interval_s = float(poll_interval_s) if poll_interval_s is not None else None

        self.step_count: int = 0
        self.phase: str = "preflight"
        self.ci_phase_start_s: float | None = None
        self.ci_reg_start_s: float | None = None
        self.fail_fast_triggered_s: float | None = None
        self.seen_failed_job_ids: list[str] = []
        self.ci_queued_since_s: float | None = None
        self.ci_stall_active_s: float = 0.0
        self.ci_stall_last_s: float | None = None
        self.ci_runner_last_inspect_s: float | None = None
        self.ci_runner_local_busy: bool = False
        self.scheduling_stalled_emitted: bool = False
        self.ci_runner_milestone: str | None = None
        self.review_entered_s: float | None = None
        self.review_last_tick_s: float | None = None
        self.review_pickup_elapsed_s: float = 0.0
        self.review_in_active_since_s: float | None = None
        self.review_active_timeout_s: int = 1800
        self.review_retry_count: int = 0
        self.last_retry_key: str | None = None
        self.docker_unavailable_emitted: bool = False
        self.api_error_streak: int = 0
        self.api_error_advisory_emitted: bool = False
        self.last_transition_key: str | None = None

    def to_dict(self) -> dict[str, Any]:
        """Serialize state machine configuration and runtime state to JSON-safe dict."""
        return {
            "init": {
                "repo": self.repo,
                "pr": self.pr,
                "head_sha": self.head_sha,
                "fail_fast_ci": self.fail_fast_ci,
                "fail_fast_ci_grace_s": self.fail_fast_ci_grace_s,
                "wait_all_ci": self.wait_all_ci,
                "ci_runner": self.ci_runner,
                "docker_available": self.docker_available,
                "ci_max_wait_s": self.ci_max_wait_s,
                "review_pickup_timeout_s": self.review_pickup_timeout_s,
                "review_queue_ceiling_s": self.review_queue_ceiling_s,
                "auto_review_installed": self.auto_review_installed,
                "registry_project": self.registry_project,
                "pr_branch": self.pr_branch,
                "pr_labels": self.pr_labels,
                "workflows_present": self.workflows_present,
                "only_base_merges": self.only_base_merges,
                "poll_interval_s": self.poll_interval_s,
            },
            "state": {
                "step_count": self.step_count,
                "phase": self.phase,
                "ci_phase_start_s": self.ci_phase_start_s,
                "ci_reg_start_s": self.ci_reg_start_s,
                "fail_fast_triggered_s": self.fail_fast_triggered_s,
                "seen_failed_job_ids": list(self.seen_failed_job_ids),
                "ci_queued_since_s": self.ci_queued_since_s,
                "ci_stall_active_s": self.ci_stall_active_s,
                "ci_stall_last_s": self.ci_stall_last_s,
                "ci_runner_last_inspect_s": self.ci_runner_last_inspect_s,
                "ci_runner_local_busy": self.ci_runner_local_busy,
                "scheduling_stalled_emitted": self.scheduling_stalled_emitted,
                "ci_runner_milestone": self.ci_runner_milestone,
                "review_entered_s": self.review_entered_s,
                "review_last_tick_s": self.review_last_tick_s,
                "review_pickup_elapsed_s": self.review_pickup_elapsed_s,
                "review_in_active_since_s": self.review_in_active_since_s,
                "review_active_timeout_s": self.review_active_timeout_s,
                "review_retry_count": self.review_retry_count,
                "last_retry_key": self.last_retry_key,
                "docker_unavailable_emitted": self.docker_unavailable_emitted,
                "api_error_streak": self.api_error_streak,
                "api_error_advisory_emitted": self.api_error_advisory_emitted,
                "last_transition_key": self.last_transition_key,
            },
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> WatchStateMachine:
        """Restore a WatchStateMachine from a dict produced by to_dict()."""
        sm = cls(**dict(data["init"]))
        st = data.get("state") or {}
        for key, val in st.items():
            if hasattr(sm, key):
                setattr(sm, key, list(val) if key == "seen_failed_job_ids" else val)
        return sm

    def _base_poll_s(self) -> float:
        if self.poll_interval_s is not None:
            return self.poll_interval_s
        return compute_poll_interval(self.step_count - 1)

    def _result(
        self,
        *,
        terminal: bool,
        exit_code: int | None,
        status: str | None,
        gate_line: str | None,
        events: list[dict[str, Any]],
        next_poll_s: float = 0.0,
        need_ci_runner_inspect: bool = False,
        need_auto_review_cli_status: bool = False,
    ) -> dict[str, Any]:
        return {
            "terminal": terminal,
            "exit_code": exit_code,
            "status": status,
            "gate_line": gate_line,
            "events": events,
            "next_poll_s": next_poll_s,
            "need_ci_runner_inspect": need_ci_runner_inspect,
            "need_auto_review_cli_status": need_auto_review_cli_status,
            "phase": self.phase,
        }

    def _terminal_blocked(
        self,
        *,
        ts_str: str,
        head_sha: str,
        phase: str,
        event: str,
        code: str,
        summary: str,
        diagnostic: dict[str, Any] | None = None,
        events: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        self.phase = "terminal"
        gate_line = f"7|BLOCKED_INFRA|0|{summary}"
        ev = build_ndjson_event(
            ts=ts_str,
            repo=self.repo,
            pr=self.pr,
            head_sha=head_sha,
            phase=phase,
            event=event,
            severity="terminal",
            code=code,
            summary=summary,
            diagnostic=diagnostic,
            gate=gate_line,
        )
        all_events = list(events or []) + [ev]
        return self._result(
            terminal=True,
            exit_code=7,
            status="BLOCKED_INFRA",
            gate_line=gate_line,
            events=all_events,
        )

    def _maybe_transition_event(
        self,
        *,
        transition_key: str,
        ts_str: str,
        head_sha: str,
        phase: str,
        event: str,
        code: str,
        summary: str,
        diagnostic: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        if self.last_transition_key == transition_key:
            return []
        self.last_transition_key = transition_key
        return [
            build_ndjson_event(
                ts=ts_str,
                repo=self.repo,
                pr=self.pr,
                head_sha=head_sha,
                phase=phase,
                event=event,
                severity="info",
                code=code,
                summary=summary,
                diagnostic=diagnostic,
            )
        ]

    def _check_registry_skip(self, ts_str: str, head_sha: str) -> dict[str, Any] | None:
        rp = self.registry_project
        if not isinstance(rp, Mapping):
            return None
        if rp.get("paused") is True:
            reason = str(rp.get("paused_reason") or "auto-review is paused for repository")
            return self._terminal_blocked(
                ts_str=ts_str,
                head_sha=head_sha,
                phase="review",
                event="auto_review_paused",
                code="AUTO_REVIEW_PAUSED",
                summary=scrub_secrets(reason),
                diagnostic={
                    "paused": True,
                    "remediation": f"docker exec -u 10001 auto-review auto-review resume {self.repo}",
                },
            )
        if rp.get("enabled") is False:
            return self._terminal_blocked(
                ts_str=ts_str,
                head_sha=head_sha,
                phase="review",
                event="auto_review_disabled",
                code="AUTO_REVIEW_DISABLED",
                summary=f"auto-review is disabled for {self.repo}",
                diagnostic={
                    "enabled": False,
                    "remediation": f"docker exec -u 10001 auto-review auto-review resume {self.repo}",
                },
            )
        branch_pats = _as_str_list(rp.get("skip_branch")) + _as_str_list(rp.get("skip_branches"))
        matched_branch = _matches_any_glob(self.pr_branch, branch_pats)
        if matched_branch is not None:
            return self._terminal_blocked(
                ts_str=ts_str,
                head_sha=head_sha,
                phase="review",
                event="auto_review_skip_branch",
                code="AUTO_REVIEW_SKIP_BRANCH",
                summary=f"auto-review skips branch {self.pr_branch!r} (matches {matched_branch!r})",
                diagnostic={"branch": self.pr_branch, "skip_branch": matched_branch},
            )
        label_pats = _as_str_list(rp.get("skip_label")) + _as_str_list(rp.get("skip_labels"))
        for lbl in self.pr_labels:
            matched_lbl = _matches_any_glob(lbl, label_pats)
            if matched_lbl is not None:
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=head_sha,
                    phase="review",
                    event="auto_review_skip_label",
                    code="AUTO_REVIEW_SKIP_LABEL",
                    summary=f"auto-review skips PR label {lbl!r} (matches {matched_lbl!r})",
                    diagnostic={"label": lbl, "skip_label": matched_lbl},
                )
        return None

    def step(
        self,
        now_s: float,
        snapshot: Mapping[str, Any],
        *,
        ts: str | None = None,
    ) -> dict[str, Any]:
        """Advance the watch state machine by one poll snapshot."""
        self.step_count += 1
        now = float(now_s)
        ts_str = _format_ts(now, ts)
        snap_sha = str(snapshot.get("head_sha") or self.head_sha)

        # 1. HEAD_DRIFTED check on every poll
        if snap_sha and self.head_sha and snap_sha != self.head_sha:
            gate_line = f"6|HEAD_DRIFTED|0|pull request head changed ({self.head_sha[:7]} -> {snap_sha[:7]})"
            ev = build_ndjson_event(
                ts=ts_str,
                repo=self.repo,
                pr=self.pr,
                head_sha=snap_sha,
                phase=self.phase,
                event="head_drifted",
                severity="terminal",
                code="HEAD_DRIFTED",
                summary=f"PR head drifted from {self.head_sha[:7]} to {snap_sha[:7]}",
                diagnostic={"old_sha": self.head_sha, "new_sha": snap_sha},
                gate=gate_line,
            )
            self.phase = "terminal"
            return self._result(
                terminal=True,
                exit_code=6,
                status="HEAD_DRIFTED",
                gate_line=gate_line,
                events=[ev],
            )

        # 2. Transient API error backoff & recovery
        api_error = snapshot.get("api_error")
        if api_error:
            self.api_error_streak += 1
            err_msg = scrub_secrets(str(api_error))
            if self.api_error_streak >= 6:
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=snap_sha,
                    phase=self.phase,
                    event="api_unreachable",
                    code="API_UNREACHABLE",
                    summary=f"GitHub API failed {self.api_error_streak} consecutive times: {err_msg}",
                    diagnostic={"consecutive_failures": self.api_error_streak, "error": err_msg},
                )
            events: list[dict[str, Any]] = []
            if self.api_error_streak == 2 and not self.api_error_advisory_emitted:
                self.api_error_advisory_emitted = True
                events.append(
                    build_ndjson_event(
                        ts=ts_str,
                        repo=self.repo,
                        pr=self.pr,
                        head_sha=snap_sha,
                        phase=self.phase,
                        event="api_error_transient",
                        severity="advisory",
                        code="API_TRANSIENT_ERROR",
                        summary=f"Transient GitHub API error (attempt {self.api_error_streak}): {err_msg}",
                        diagnostic={"consecutive_failures": self.api_error_streak, "error": err_msg},
                    )
                )
            backoff_s = _BACKOFF_SCHEDULE_S[min(self.api_error_streak - 1, len(_BACKOFF_SCHEDULE_S) - 1)]
            return self._result(
                terminal=False,
                exit_code=None,
                status=None,
                gate_line=None,
                events=events,
                next_poll_s=backoff_s,
            )

        recovery_events: list[dict[str, Any]] = []
        if self.api_error_streak > 0:
            prev_streak = self.api_error_streak
            self.api_error_streak = 0
            self.api_error_advisory_emitted = False
            recovery_events.append(
                build_ndjson_event(
                    ts=ts_str,
                    repo=self.repo,
                    pr=self.pr,
                    head_sha=snap_sha,
                    phase=self.phase,
                    event="api_recovered",
                    severity="info",
                    code="API_RECOVERED",
                    summary=f"GitHub API recovered after {prev_streak} transient failure(s)",
                    diagnostic={"previous_failures": prev_streak},
                )
            )

        gate_line = str(snapshot.get("gate_decision") or "")
        gate_rc, gate_status, _allow_admin, gate_reason = _parse_gate_line(gate_line)
        ci_state = str(snapshot.get("ci_state") or "")
        review_state = str(snapshot.get("review_state") or "")
        runs = snapshot.get("runs") if isinstance(snapshot.get("runs"), list) else []
        jobs_by_run = snapshot.get("jobs_by_run") if isinstance(snapshot.get("jobs_by_run"), Mapping) else {}

        # 3. Preflight & terminal gate verdicts
        if gate_status in _PREFLIGHT_FAIL_FAST_STATUSES:
            self.phase = "terminal"
            ev = build_ndjson_event(
                ts=ts_str,
                repo=self.repo,
                pr=self.pr,
                head_sha=snap_sha,
                phase="terminal",
                event="gate_terminal",
                severity="terminal",
                code=gate_status,
                summary=gate_reason or gate_status,
                gate=gate_line,
            )
            return self._result(
                terminal=True,
                exit_code=gate_rc,
                status=gate_status,
                gate_line=gate_line,
                events=recovery_events + [ev],
            )

        # 4. WAIT_MERGEABLE: do not fail-fast
        if gate_status == "WAIT_MERGEABLE":
            self.phase = "preflight"
            evs = recovery_events + self._maybe_transition_event(
                transition_key="wait_mergeable",
                ts_str=ts_str,
                head_sha=snap_sha,
                phase="preflight",
                event="wait_mergeable",
                code="WAIT_MERGEABLE",
                summary=gate_reason or "Waiting for GitHub mergeability calculation",
            )
            return self._result(
                terminal=False,
                exit_code=None,
                status="WAIT_MERGEABLE",
                gate_line=None,
                events=evs,
                next_poll_s=self._base_poll_s(),
            )

        # 5. NEEDS_META (distinguish settled_no_ci registration grace vs immediate NEEDS_META)
        if gate_status == "NEEDS_META":
            if ci_state == "settled_no_ci" and not runs:
                if self.workflows_present:
                    if self.ci_reg_start_s is None:
                        self.ci_reg_start_s = now
                    elapsed_reg = now - self.ci_reg_start_s
                    if elapsed_reg >= 60:
                        self.phase = "terminal"
                        ev = build_ndjson_event(
                            ts=ts_str,
                            repo=self.repo,
                            pr=self.pr,
                            head_sha=snap_sha,
                            phase="ci_awaiting_registration",
                            event="ci_registration_timed_out",
                            severity="terminal",
                            code="NEEDS_META",
                            summary="Workflow files exist on head but no CI runs registered within 60s",
                            diagnostic={
                                "workflows_present": True,
                                "ci_registration_timed_out": True,
                            },
                            gate=gate_line,
                        )
                        return self._result(
                            terminal=True,
                            exit_code=gate_rc,
                            status="NEEDS_META",
                            gate_line=gate_line,
                            events=recovery_events + [ev],
                        )
                    self.phase = "ci_awaiting_registration"
                    evs = recovery_events + self._maybe_transition_event(
                        transition_key="ci_awaiting_registration",
                        ts_str=ts_str,
                        head_sha=snap_sha,
                        phase="ci_awaiting_registration",
                        event="ci_awaiting_registration",
                        code="WAIT_CI",
                        summary="Waiting up to 60s for GitHub Actions runs to register",
                        diagnostic={"workflows_present": True},
                    )
                    remaining_reg = max(1.0, 60.0 - elapsed_reg)
                    return self._result(
                        terminal=False,
                        exit_code=None,
                        status="WAIT_CI",
                        gate_line=None,
                        events=evs,
                        next_poll_s=min(self._base_poll_s(), remaining_reg),
                    )
                self.phase = "terminal"
                ev = build_ndjson_event(
                    ts=ts_str,
                    repo=self.repo,
                    pr=self.pr,
                    head_sha=snap_sha,
                    phase="terminal",
                    event="gate_terminal",
                    severity="terminal",
                    code="NEEDS_META",
                    summary=gate_reason or "No CI configured for commit",
                    diagnostic={
                        "workflows_present": False,
                        "ci_registration_timed_out": False,
                    },
                    gate=gate_line,
                )
                return self._result(
                    terminal=True,
                    exit_code=gate_rc,
                    status="NEEDS_META",
                    gate_line=gate_line,
                    events=recovery_events + [ev],
                )

            self.phase = "terminal"
            ev = build_ndjson_event(
                ts=ts_str,
                repo=self.repo,
                pr=self.pr,
                head_sha=snap_sha,
                phase="terminal",
                event="gate_terminal",
                severity="terminal",
                code="NEEDS_META",
                summary=gate_reason or "NEEDS_META",
                gate=gate_line,
            )
            return self._result(
                terminal=True,
                exit_code=gate_rc,
                status="NEEDS_META",
                gate_line=gate_line,
                events=recovery_events + [ev],
            )

        # 6. CI phase
        has_active_runs = any(
            isinstance(r, dict) and str(r.get("status") or "") != "completed" for r in runs
        )
        if ci_state == "pending" or gate_status == "WAIT_CI" or has_active_runs:
            return self._step_ci(
                now=now,
                ts_str=ts_str,
                head_sha=snap_sha,
                runs=runs,
                jobs_by_run=jobs_by_run,
                snapshot=snapshot,
                events=recovery_events,
            )

        # 7. Review phase (starts ONLY after CI settles green / not pending)
        if gate_status == "WAIT_REVIEW" or review_state == "wait_review":
            return self._step_review(
                now=now,
                ts_str=ts_str,
                head_sha=snap_sha,
                snapshot=snapshot,
                events=recovery_events,
            )

        return self._result(
            terminal=False,
            exit_code=None,
            status=gate_status,
            gate_line=None,
            events=recovery_events,
            next_poll_s=self._base_poll_s(),
        )

    def _step_ci(
        self,
        *,
        now: float,
        ts_str: str,
        head_sha: str,
        runs: list[dict[str, Any]],
        jobs_by_run: Mapping[Any, list[dict[str, Any]]],
        snapshot: Mapping[str, Any],
        events: list[dict[str, Any]],
    ) -> dict[str, Any]:
        self.phase = "ci"
        if self.ci_phase_start_s is None:
            self.ci_phase_start_s = now

        out_events = list(events) + self._maybe_transition_event(
            transition_key="ci_waiting",
            ts_str=ts_str,
            head_sha=head_sha,
            phase="ci",
            event="ci_waiting",
            code="WAIT_CI",
            summary=f"Waiting for CI ({len(runs)} run(s))",
        )

        # 6a. Early job failure detection & --fail-fast-ci debounce
        failed_jobs, pending_jobs, passed_jobs = _classify_jobs(runs, jobs_by_run)
        if failed_jobs and (pending_jobs or any(isinstance(r, dict) and r.get("status") != "completed" for r in runs)):
            new_fail_ids: list[str] = []
            for fj in failed_jobs:
                jid = str(fj.get("id") if fj.get("id") is not None else fj.get("name") or "")
                if jid and jid not in self.seen_failed_job_ids:
                    new_fail_ids.append(jid)
                    self.seen_failed_job_ids.append(jid)
            if new_fail_ids:
                if self.fail_fast_triggered_s is None:
                    self.fail_fast_triggered_s = now
                failed_names = ", ".join(str(j.get("name") or "unknown") for j in failed_jobs)
                out_events.append(
                    build_ndjson_event(
                        ts=ts_str,
                        repo=self.repo,
                        pr=self.pr,
                        head_sha=head_sha,
                        phase="ci",
                        event="ci_job_failed_early",
                        severity="advisory",
                        code="FIX_CI",
                        summary=f"CI job failed early while {len(pending_jobs)} job(s) still pending: {failed_names}",
                        diagnostic={
                            "failed_jobs": failed_jobs,
                            "pending_jobs": pending_jobs,
                            "passed_jobs": passed_jobs,
                        },
                    )
                )
            if self.fail_fast_ci and self.fail_fast_triggered_s is not None:
                elapsed_ff = now - self.fail_fast_triggered_s
                if elapsed_ff >= self.fail_fast_ci_grace_s:
                    failed_names = ", ".join(str(j.get("name") or "unknown") for j in failed_jobs)
                    gate_line = f"3|FIX_CI|0|CI failed on head ({failed_names})"
                    self.phase = "terminal"
                    out_events.append(
                        build_ndjson_event(
                            ts=ts_str,
                            repo=self.repo,
                            pr=self.pr,
                            head_sha=head_sha,
                            phase="ci",
                            event="ci_failed_fast",
                            severity="terminal",
                            code="FIX_CI",
                            summary=f"CI failed fast after {int(elapsed_ff)}s grace ({failed_names})",
                            diagnostic={
                                "failed_jobs": failed_jobs,
                                "pending_jobs": pending_jobs,
                                "passed_jobs": passed_jobs,
                                "grace_s": self.fail_fast_ci_grace_s,
                            },
                            gate=gate_line,
                        )
                    )
                    return self._result(
                        terminal=True,
                        exit_code=3,
                        status="FIX_CI",
                        gate_line=gate_line,
                        events=out_events,
                    )

        # 6b. Queued run health & GitHub Actions scheduling stall detection
        any_queued_run = any(isinstance(r, dict) and r.get("status") == "queued" for r in runs)
        any_in_progress_run = any(isinstance(r, dict) and r.get("status") == "in_progress" for r in runs)
        any_in_progress_job = any(j.get("status") == "in_progress" for j in pending_jobs)
        need_ci_runner_inspect = False

        if any_queued_run and not any_in_progress_run and not any_in_progress_job:
            if self.ci_queued_since_s is None:
                self.ci_queued_since_s = now
            queued_seconds = now - self.ci_queued_since_s

            ci_runner_inspect = snapshot.get("ci_runner_inspect")
            ci_runner_status = snapshot.get("ci_runner_status")
            ci_runner_logs = str(snapshot.get("ci_runner_logs") or "")

            if ci_runner_inspect is not None or ci_runner_status is not None:
                self.ci_runner_last_inspect_s = now
            elif (
                self.ci_runner == 1
                and self.docker_available
                and queued_seconds > 30
                and (
                    self.ci_runner_last_inspect_s is None
                    or (now - self.ci_runner_last_inspect_s) >= 60
                )
            ):
                need_ci_runner_inspect = True

            runner_healthy: bool | None = None
            gate_used: int | None = None
            gate_budget: int | None = None
            gate_queue_has_repo = False

            if self.ci_runner == 1 and self.docker_available and (
                ci_runner_inspect is not None or ci_runner_status is not None
            ):
                is_down, down_info = _container_down_info(ci_runner_inspect)
                if is_down:
                    scrubbed_logs = scrub_secrets(_tail_lines(ci_runner_logs))
                    return self._terminal_blocked(
                        ts_str=ts_str,
                        head_sha=head_sha,
                        phase="ci",
                        event="ci_runner_down",
                        code="CI_RUNNER_DOWN",
                        summary="Local docker-ci-gate-gate container is down",
                        diagnostic={
                            **down_info,
                            "logs_tail": scrubbed_logs,
                            "remediation": "cd ~/Projects/host-repo && tools/docker-ci-gate/docker-ci-gate.sh up",
                        },
                        events=out_events,
                    )

                if isinstance(ci_runner_status, Mapping):
                    if ci_runner_status.get("locked") is True:
                        return self._terminal_blocked(
                            ts_str=ts_str,
                            head_sha=head_sha,
                            phase="ci",
                            event="ci_runner_locked",
                            code="CI_RUNNER_LOCKED",
                            summary="Local docker-ci-gate-gate is locked (no credential after reboot)",
                            diagnostic={
                                "locked": True,
                                "remediation": "cd ~/Projects/host-repo && tools/docker-ci-gate/docker-ci-gate.sh unlock",
                            },
                            events=out_events,
                        )
                    if ci_runner_status.get("paused") is True:
                        return self._terminal_blocked(
                            ts_str=ts_str,
                            head_sha=head_sha,
                            phase="ci",
                            event="ci_runner_paused",
                            code="CI_RUNNER_PAUSED",
                            summary="Local docker-ci-gate-gate is paused",
                            diagnostic={
                                "paused": True,
                                "remediation": "cd ~/Projects/host-repo && tools/docker-ci-gate/docker-ci-gate.sh resume",
                            },
                            events=out_events,
                        )

                    waiting = ci_runner_status.get("waiting")
                    draining = ci_runner_status.get("draining")
                    used = ci_runner_status.get("used")
                    budget = ci_runner_status.get("budget")
                    gate_used = int(used) if isinstance(used, (int, float)) else None
                    gate_budget = int(budget) if isinstance(budget, (int, float)) else None
                    queue_items = ci_runner_status.get("queue") or []
                    gate_queue_has_repo = any(
                        isinstance(q, Mapping) and q.get("repo") == self.repo for q in queue_items
                    )

                    if waiting is not None:
                        self.ci_runner_local_busy = True
                        mkey = f"waiting:{waiting}"
                        if self.ci_runner_milestone != mkey:
                            self.ci_runner_milestone = mkey
                            out_events.append(
                                build_ndjson_event(
                                    ts=ts_str,
                                    repo=self.repo,
                                    pr=self.pr,
                                    head_sha=head_sha,
                                    phase="ci",
                                    event="ci_runner_waiting",
                                    severity="info",
                                    code="WAIT_CI",
                                    summary=f"Local docker-ci-gate queued: waiting on {waiting}",
                                    diagnostic={"waiting": waiting, "used": used, "budget": budget},
                                )
                            )
                    elif draining is not None:
                        self.ci_runner_local_busy = True
                        mkey = "draining"
                        if self.ci_runner_milestone != mkey:
                            self.ci_runner_milestone = mkey
                            out_events.append(
                                build_ndjson_event(
                                    ts=ts_str,
                                    repo=self.repo,
                                    pr=self.pr,
                                    head_sha=head_sha,
                                    phase="ci",
                                    event="ci_runner_draining",
                                    severity="info",
                                    code="WAIT_CI",
                                    summary="Local docker-ci-gate queued: draining for mega job",
                                    diagnostic={"draining": draining, "used": used, "budget": budget},
                                )
                            )
                    elif gate_used is not None and gate_budget is not None and gate_budget > 0 and gate_used >= gate_budget:
                        self.ci_runner_local_busy = True
                        mkey = f"budget:{gate_used}/{gate_budget}"
                        if self.ci_runner_milestone != mkey:
                            self.ci_runner_milestone = mkey
                            out_events.append(
                                build_ndjson_event(
                                    ts=ts_str,
                                    repo=self.repo,
                                    pr=self.pr,
                                    head_sha=head_sha,
                                    phase="ci",
                                    event="ci_runner_budget_full",
                                    severity="info",
                                    code="WAIT_CI",
                                    summary=f"Local docker-ci-gate capacity full ({gate_used}/{gate_budget} cores)",
                                    diagnostic={"used": gate_used, "budget": gate_budget},
                                )
                            )
                    else:
                        self.ci_runner_local_busy = False
                        runner_healthy = True

            if self.ci_runner_local_busy:
                self.ci_stall_last_s = now
            else:
                if self.ci_stall_last_s is None:
                    self.ci_stall_active_s = queued_seconds
                else:
                    self.ci_stall_active_s += max(0.0, now - self.ci_stall_last_s)
                self.ci_stall_last_s = now

                stall_advisory_s = 180 if (self.ci_runner == 1 and self.docker_available) else 300
                stall_diag = {
                    "runner_healthy": runner_healthy,
                    "gate_used": gate_used,
                    "gate_budget": gate_budget,
                    "gate_queue_has_repo": gate_queue_has_repo,
                    "queued_seconds": int(queued_seconds),
                }
                if self.ci_stall_active_s >= 900:
                    return self._terminal_blocked(
                        ts_str=ts_str,
                        head_sha=head_sha,
                        phase="ci",
                        event="ci_github_scheduling_timeout",
                        code="CI_GITHUB_SCHEDULING_TIMEOUT",
                        summary=f"GitHub Actions scheduling stalled in queued state for {int(queued_seconds)}s",
                        diagnostic=stall_diag,
                        events=out_events,
                    )
                if self.ci_stall_active_s >= stall_advisory_s and not self.scheduling_stalled_emitted:
                    self.scheduling_stalled_emitted = True
                    out_events.append(
                        build_ndjson_event(
                            ts=ts_str,
                            repo=self.repo,
                            pr=self.pr,
                            head_sha=head_sha,
                            phase="ci",
                            event="ci_github_scheduling_stalled",
                            severity="advisory",
                            code="CI_GITHUB_SCHEDULING_STALLED",
                            summary=f"CI run queued for {int(queued_seconds)}s with 0 jobs advancing",
                            diagnostic=stall_diag,
                        )
                    )
        else:
            self.ci_queued_since_s = None
            self.ci_stall_active_s = 0.0
            self.ci_stall_last_s = None
            self.ci_runner_local_busy = False
            self.scheduling_stalled_emitted = False
            self.ci_runner_milestone = None

        if (now - self.ci_phase_start_s) >= self.ci_max_wait_s:
            return self._terminal_blocked(
                ts_str=ts_str,
                head_sha=head_sha,
                phase="ci",
                event="ci_max_wait_exceeded",
                code="CI_MAX_WAIT_EXCEEDED",
                summary=f"CI did not settle within ci_max_wait_seconds ({self.ci_max_wait_s}s)",
                diagnostic={"elapsed_s": int(now - self.ci_phase_start_s), "ci_max_wait_s": self.ci_max_wait_s},
                events=out_events,
            )

        next_poll = self._base_poll_s()
        if self.fail_fast_ci and self.fail_fast_triggered_s is not None:
            rem_ff = max(1.0, self.fail_fast_ci_grace_s - (now - self.fail_fast_triggered_s))
            next_poll = min(next_poll, rem_ff)

        return self._result(
            terminal=False,
            exit_code=None,
            status="WAIT_CI",
            gate_line=None,
            events=out_events,
            next_poll_s=next_poll,
            need_ci_runner_inspect=need_ci_runner_inspect,
        )

    def _step_review(
        self,
        *,
        now: float,
        ts_str: str,
        head_sha: str,
        snapshot: Mapping[str, Any],
        events: list[dict[str, Any]],
    ) -> dict[str, Any]:
        entering_review = self.phase != "review"
        self.phase = "review"
        if self.review_entered_s is None:
            self.review_entered_s = now
            self.review_last_tick_s = now

        reg_block = self._check_registry_skip(ts_str, head_sha)
        if reg_block is not None:
            reg_block["events"] = list(events) + reg_block["events"]
            return reg_block

        out_events = list(events) + self._maybe_transition_event(
            transition_key="review_waiting",
            ts_str=ts_str,
            head_sha=head_sha,
            phase="review",
            event="review_waiting",
            code="WAIT_REVIEW",
            summary="CI green; waiting for auto-review on current head",
        )

        if not self.docker_available:
            if not self.docker_unavailable_emitted:
                self.docker_unavailable_emitted = True
                out_events.append(
                    build_ndjson_event(
                        ts=ts_str,
                        repo=self.repo,
                        pr=self.pr,
                        head_sha=head_sha,
                        phase="review",
                        event="review_docker_unavailable",
                        severity="info",
                        code="WAIT_REVIEW",
                        summary="Docker unavailable in environment; watching auto-review via GitHub API only",
                    )
                )
            dt_s = max(0.0, now - (self.review_last_tick_s if self.review_last_tick_s is not None else now))
            self.review_last_tick_s = now
            self.review_pickup_elapsed_s += dt_s
            if self.review_pickup_elapsed_s >= self.review_pickup_timeout_s:
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=head_sha,
                    phase="review",
                    event="auto_review_pickup_timeout",
                    code="AUTO_REVIEW_PICKUP_TIMEOUT",
                    summary=f"auto-review did not land within {self.review_pickup_timeout_s}s",
                    diagnostic={"elapsed_s": int(self.review_pickup_elapsed_s)},
                    events=out_events,
                )
            return self._result(
                terminal=False,
                exit_code=None,
                status="WAIT_REVIEW",
                gate_line=None,
                events=out_events,
                next_poll_s=self._base_poll_s(),
            )

        ar_inspect = snapshot.get("auto_review_inspect")
        ar_logs = str(snapshot.get("auto_review_logs") or "")
        is_down, down_info = _container_down_info(ar_inspect)
        if is_down:
            scrubbed_logs = scrub_secrets(_tail_lines(ar_logs))
            return self._terminal_blocked(
                ts_str=ts_str,
                head_sha=head_sha,
                phase="review",
                event="auto_review_daemon_down",
                code="AUTO_REVIEW_DAEMON_DOWN",
                summary="auto-review container is down or restarting",
                diagnostic={
                    **down_info,
                    "logs_tail": scrubbed_logs,
                    "remediation": "cd ~/Projects/host-repo && docker compose -f tools/auto-review/docker-compose.yml up -d",
                },
                events=out_events,
            )

        ar_status = snapshot.get("auto_review_status")
        need_cli_status = entering_review
        active_list: list[dict[str, Any]] = []
        queued_list: list[dict[str, Any]] = []
        ar_phase = ""

        if isinstance(ar_status, Mapping):
            ar_phase = str(ar_status.get("phase") or "")
            active_raw = ar_status.get("active")
            if isinstance(active_raw, list):
                active_list = [a for a in active_raw if isinstance(a, dict)]
            queued_raw = ar_status.get("queued")
            if isinstance(queued_raw, list):
                queued_list = [q for q in queued_raw if isinstance(q, dict)]

            harnesses = ar_status.get("harnesses")
            if isinstance(harnesses, Mapping):
                for h_name, h_info in harnesses.items():
                    if isinstance(h_info, Mapping) and h_info.get("state") == "fault":
                        msg = scrub_secrets(str(h_info.get("message") or "harness fault"))
                        return self._terminal_blocked(
                            ts_str=ts_str,
                            head_sha=head_sha,
                            phase="review",
                            event="auto_review_harness_fault",
                            code="AUTO_REVIEW_HARNESS_FAULT",
                            summary=f"auto-review harness {h_name} in fault: {msg}",
                            diagnostic={
                                "harness": h_name,
                                "reason": msg,
                                "remediation": f"docker exec -u 10001 auto-review auto-review login {h_name}",
                            },
                            events=out_events,
                        )
            tokens = ar_status.get("tokens")
            if isinstance(tokens, list) and tokens:
                first_tok = tokens[0] if isinstance(tokens[0], Mapping) else {}
                t_name = str(first_tok.get("name") or "token")
                t_prob = str(first_tok.get("problem") or "invalid")
                rem = str(first_tok.get("command") or "tools/auto-review/unlock-token.sh")
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=head_sha,
                    phase="review",
                    event="auto_review_token_problem",
                    code="AUTO_REVIEW_TOKEN_PROBLEM",
                    summary=f"auto-review token problem ({t_name}: {t_prob})",
                    diagnostic={"tokens": tokens, "remediation": rem},
                    events=out_events,
                )

            tick_errors = ar_status.get("tick_errors")
            if isinstance(tick_errors, Mapping):
                for scope in ("_global", self.repo):
                    te = tick_errors.get(scope)
                    if not isinstance(te, Mapping):
                        continue
                    need_cli_status = True
                    ek = str(te.get("error_kind") or "tick_error")
                    reason = scrub_secrets(str(te.get("reason") or ek))
                    if not _is_retryable_error(ek, te.get("retryable")):
                        return self._terminal_blocked(
                            ts_str=ts_str,
                            head_sha=head_sha,
                            phase="review",
                            event="auto_review_tick_error",
                            code="AUTO_REVIEW_TICK_ERROR",
                            summary=f"auto-review tick error ({ek}): {reason}",
                            diagnostic={
                                "scope": scope,
                                "error_kind": ek,
                                "reason": reason,
                                "retryable": False,
                                "remediation": "docker exec -u 10001 auto-review auto-review status --json",
                            },
                            events=out_events,
                        )
                    rkey = f"tick:{scope}:{ek}:{te.get('at', '')}"
                    if self.last_retry_key != rkey:
                        self.last_retry_key = rkey
                        self.review_retry_count += 1
                        self.review_pickup_elapsed_s = 0.0
                        if self.review_retry_count > 2:
                            return self._terminal_blocked(
                                ts_str=ts_str,
                                head_sha=head_sha,
                                phase="review",
                                event="auto_review_retry_exhausted",
                                code="AUTO_REVIEW_RETRY_EXHAUSTED",
                                summary=f"auto-review retryable tick error persisted ({ek}): {reason}",
                                diagnostic={
                                    "scope": scope,
                                    "error_kind": ek,
                                    "reason": reason,
                                    "attempts": self.review_retry_count,
                                },
                                events=out_events,
                            )
                        out_events.append(
                            build_ndjson_event(
                                ts=ts_str,
                                repo=self.repo,
                                pr=self.pr,
                                head_sha=head_sha,
                                phase="review",
                                event="auto_review_retryable_error",
                                severity="advisory",
                                code="AUTO_REVIEW_RETRYABLE_ERROR",
                                summary=f"auto-review retryable tick error ({ek}): {reason}",
                                diagnostic={
                                    "scope": scope,
                                    "error_kind": ek,
                                    "reason": reason,
                                    "retryable": True,
                                    "attempts": self.review_retry_count,
                                },
                            )
                        )

            recent_results = ar_status.get("recent_results")
            pr_key = f"{self.repo}#{self.pr}"
            if isinstance(recent_results, Mapping) and isinstance(recent_results.get(pr_key), Mapping):
                rr = recent_results[pr_key]
                rr_sha = str(rr.get("sha") or "")
                rr_result = str(rr.get("result") or "")
                rr_ek = str(rr.get("error_kind") or "")
                if _sha_matches(rr_sha, head_sha) and (
                    rr_ek != "" or rr_result not in ("", "posted", "clean", "skipped_low_risk")
                ):
                    need_cli_status = True
                    reason = scrub_secrets(str(rr.get("reason") or rr_ek or rr_result))
                    retryable = _is_retryable_error(rr_ek, rr.get("retryable"))
                    if not retryable:
                        return self._terminal_blocked(
                            ts_str=ts_str,
                            head_sha=head_sha,
                            phase="review",
                            event="auto_review_failed",
                            code="AUTO_REVIEW_FAILED",
                            summary=f"auto-review failed ({rr_ek or rr_result}): {reason}",
                            diagnostic={
                                "error_kind": rr_ek,
                                "reason": reason,
                                "retryable": False,
                                "http_status": rr.get("http_status"),
                                "remediation": "docker exec -u 10001 auto-review auto-review status --json",
                            },
                            events=out_events,
                        )
                    attempts_raw = rr.get("attempts")
                    rkey = f"rr:{rr_sha}:{rr_ek}:{attempts_raw}:{rr.get('at', '')}"
                    if self.last_retry_key != rkey:
                        self.last_retry_key = rkey
                        if isinstance(attempts_raw, int) and not isinstance(attempts_raw, bool) and attempts_raw >= 1:
                            eff_attempts = attempts_raw
                            self.review_retry_count = max(self.review_retry_count + 1, attempts_raw)
                        else:
                            self.review_retry_count += 1
                            eff_attempts = self.review_retry_count
                        self.review_pickup_elapsed_s = 0.0
                        if eff_attempts > 2:
                            return self._terminal_blocked(
                                ts_str=ts_str,
                                head_sha=head_sha,
                                phase="review",
                                event="auto_review_retry_exhausted",
                                code="AUTO_REVIEW_RETRY_EXHAUSTED",
                                summary=f"auto-review retryable error exhausted after {eff_attempts} attempts ({rr_ek}): {reason}",
                                diagnostic={
                                    "error_kind": rr_ek,
                                    "reason": reason,
                                    "retryable": True,
                                    "attempts": eff_attempts,
                                },
                                events=out_events,
                            )
                        out_events.append(
                            build_ndjson_event(
                                ts=ts_str,
                                repo=self.repo,
                                pr=self.pr,
                                head_sha=head_sha,
                                phase="review",
                                event="auto_review_retryable_error",
                                severity="advisory",
                                code="AUTO_REVIEW_RETRYABLE_ERROR",
                                summary=f"auto-review retryable error ({rr_ek}, attempt {eff_attempts}): {reason}",
                                diagnostic={
                                    "error_kind": rr_ek,
                                    "reason": reason,
                                    "retryable": True,
                                    "attempts": eff_attempts,
                                },
                            )
                        )

            last_tick_epoch = _parse_timestamp_epoch(ar_status.get("last_tick_at"))
            interval_raw = ar_status.get("interval_s")
            interval_s = int(interval_raw) if isinstance(interval_raw, (int, float)) and interval_raw > 0 else 180
            if not active_list and last_tick_epoch is not None:
                stale_age = now - last_tick_epoch
                if stale_age > (2 * interval_s + 60):
                    need_cli_status = True
                    return self._terminal_blocked(
                        ts_str=ts_str,
                        head_sha=head_sha,
                        phase="review",
                        event="auto_review_stale_tick",
                        code="AUTO_REVIEW_STALE_TICK",
                        summary=f"auto-review daemon tick is stale ({int(stale_age)}s old > {2 * interval_s + 60}s) with no active reviews",
                        diagnostic={
                            "stale_seconds": int(stale_age),
                            "interval_s": interval_s,
                            "remediation": "docker exec -u 10001 auto-review auto-review status --json",
                        },
                        events=out_events,
                    )

        my_active = next(
            (a for a in active_list if a.get("repo") == self.repo and int(a.get("pr") or 0) == self.pr),
            None,
        )
        if my_active is not None:
            if self.review_in_active_since_s is None:
                self.review_in_active_since_s = now
                t_raw = my_active.get("timeout_s")
                self.review_active_timeout_s = (
                    int(t_raw) + 120
                    if isinstance(t_raw, (int, float)) and not isinstance(t_raw, bool) and t_raw > 0
                    else 1800
                )
                out_events.append(
                    build_ndjson_event(
                        ts=ts_str,
                        repo=self.repo,
                        pr=self.pr,
                        head_sha=head_sha,
                        phase="review",
                        event="review_started",
                        severity="info",
                        code="WAIT_REVIEW",
                        summary=f"auto-review actively reviewing #{self.pr} (timeout {self.review_active_timeout_s}s)",
                        diagnostic={
                            "model": my_active.get("model"),
                            "lines": my_active.get("lines"),
                            "timeout_s": self.review_active_timeout_s,
                        },
                    )
                )
            self.review_last_tick_s = now
            active_elapsed = now - self.review_in_active_since_s
            if active_elapsed >= self.review_active_timeout_s:
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=head_sha,
                    phase="review",
                    event="auto_review_run_timeout",
                    code="AUTO_REVIEW_RUN_TIMEOUT",
                    summary=f"auto-review active run exceeded {self.review_active_timeout_s}s",
                    diagnostic={"active_elapsed_s": int(active_elapsed), "timeout_s": self.review_active_timeout_s},
                    events=out_events,
                )
        else:
            self.review_in_active_since_s = None
            dt_s = max(0.0, now - (self.review_last_tick_s if self.review_last_tick_s is not None else now))
            self.review_last_tick_s = now
            other_active = any(
                not (a.get("repo") == self.repo and int(a.get("pr") or 0) == self.pr)
                for a in active_list
            )
            other_queued = any(
                not (q.get("repo") == self.repo and int(q.get("pr") or 0) == self.pr)
                for q in queued_list
            )
            paused_for_queue = (ar_phase == "scanning") or other_active or other_queued
            if not paused_for_queue:
                self.review_pickup_elapsed_s += dt_s

            total_review_elapsed = now - self.review_entered_s
            if total_review_elapsed >= self.review_queue_ceiling_s:
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=head_sha,
                    phase="review",
                    event="auto_review_queue_timeout",
                    code="AUTO_REVIEW_QUEUE_TIMEOUT",
                    summary=f"auto-review did not complete within queue ceiling ({self.review_queue_ceiling_s}s)",
                    diagnostic={"elapsed_s": int(total_review_elapsed), "ceiling_s": self.review_queue_ceiling_s},
                    events=out_events,
                )
            if self.review_pickup_elapsed_s >= self.review_pickup_timeout_s:
                return self._terminal_blocked(
                    ts_str=ts_str,
                    head_sha=head_sha,
                    phase="review",
                    event="auto_review_pickup_timeout",
                    code="AUTO_REVIEW_PICKUP_TIMEOUT",
                    summary=f"auto-review did not pick up PR within {self.review_pickup_timeout_s}s",
                    diagnostic={"pickup_elapsed_s": int(self.review_pickup_elapsed_s)},
                    events=out_events,
                )

        return self._result(
            terminal=False,
            exit_code=None,
            status="WAIT_REVIEW",
            gate_line=None,
            events=out_events,
            next_poll_s=self._base_poll_s(),
            need_auto_review_cli_status=need_cli_status,
        )
