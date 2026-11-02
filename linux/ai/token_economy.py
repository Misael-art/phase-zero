#!/usr/bin/env python3
"""Project/client token profiles and evidence; never changes provider routing.

Installed != configured != used in a session != measured provider savings.
Native rule files are additive. Existing memory lifecycle owns all MCP/hooks.
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from linux.ai.memory_manager import Manager as MemoryManager, atomic, locked, read_json, safe_path, write_json
from linux.lib.pz_hostbackup import backup_file, ledger_record

POLICY = ROOT / "assets/agent-skills/token-economy.json"
MAX_FILE = 1024 * 1024


class EconomyError(RuntimeError):
    pass


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def capture(command, *, cwd=None, timeout=8):
    try:
        return subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise EconomyError("command-unavailable-or-timeout") from None


def block(agent, profile, policy):
    label = policy["agents"][agent]["label"]
    body = [f"Token profile for {label} only: {profile}. Other clients keep their own profile.",
            "Preserve user/project instructions, account, model, permissions and all acceptance checks.",
            "ai-memory stays connected in every profile. Search relevant memory before non-trivial work; "
            "retrieve a few relevant pages, never the entire store. Record durable learnings; lifecycle owns routine capture.",
            "If memory fails or resolves another project, report degraded state and use native ai-memory "
            "from this project directory. Never invent recall or create a second memory store.",
            "Use rg/scoped reads and existing native skills/tool discovery on demand. Preserve lockfiles and diagnostics.",
            "When RTK is available, use supported filtered commands for human-readable output. "
            "rtk proxy does not filter. Use raw output for machine contracts, exact diffs and missing diagnostics."]
    if profile == "economy":
        body += ["Prefer outlines, changed symbols and failing tests before full files. Expand context when evidence is incomplete.",
                 "Answer concisely with result, evidence and limitations; preserve necessary explanation and code.",
                 "Avoid repeated scans and redundant tool outputs. Keep compact handoffs with source paths and unresolved work.",
                 "Do not disable MCP capabilities, reduce reasoning/model quality or skip tests to claim savings."]
    begin, end = markers(agent)
    return begin + "\n" + "\n".join(body) + "\n" + end


def markers(agent):
    label = "PHASEZERO TOKEN ECONOMY " + agent
    return "<!-- BEGIN " + label + " -->", "<!-- END " + label + " -->"


def extract(text, agent):
    begin, end = markers(agent)
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise EconomyError("malformed-managed-markers")
    if begin not in text:
        return None
    start = text.index(begin)
    finish = text.index(end)
    if finish < start:
        raise EconomyError("malformed-managed-markers")
    return text[start:finish + len(end)]


def native_text(path):
    safe_path(path)
    if not path.exists():
        return ""
    if path.stat().st_size > MAX_FILE:
        raise EconomyError("instruction-file-too-large")
    # Preserve CRLF/BOM and all unmanaged bytes across updates.
    return path.read_bytes().decode("utf-8")


class Economy:
    def __init__(self, project=None):
        self.policy = json.loads(POLICY.read_text())
        home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
        self.state = safe_path(home / "phasezero/ai/token-economy")
        self.registry = read_json(self.state / "profiles.json", {"schemaVersion": 1, "projects": {}})
        if self.registry.get("schemaVersion") != 1 or not isinstance(self.registry.get("projects"), dict):
            raise EconomyError("unsupported-profile-registry")
        selected = project or os.environ.get("PZ_WORKSPACE_ROOT")
        if not selected:
            p = capture(["git", "rev-parse", "--show-toplevel"], timeout=3)
            selected = p.stdout.decode().strip() if p.returncode == 0 else self.registry.get("lastProject")
        self.project = safe_path(Path(selected)) if selected else None
        if self.project and (not self.project.is_dir() or self.project in {Path.home(), Path(self.project.anchor)}):
            raise EconomyError("choose-existing-project-directory")
        self.project_id = sha(str(self.project)) if self.project else None

    def record(self):
        return self.registry["projects"].get(self.project_id, {})

    def target(self, agent):
        if not self.project:
            raise EconomyError("project-required")
        if agent not in self.policy["agents"]:
            raise EconomyError("unknown-agent")
        return safe_path(self.project / self.policy["agents"][agent]["rules"])

    def row(self, agent):
        spec = self.policy["agents"][agent]
        saved = self.record().get("agents", {}).get(agent, {})
        actual = extract(native_text(self.target(agent)), agent) if self.project else None
        matching = bool(actual and sha(actual) == saved.get("blockHash"))
        return {"id": agent, "label": spec["label"], "installed": bool(shutil.which(spec["command"])),
                "profile": saved.get("profile", "basic"), "defaultProfile": "basic",
                "configured": matching, "drift": bool(saved and not matching),
                "rules": spec["rules"], "sessionUse": "unverified", "memoryRequired": True}

    def memory(self):
        try:
            manager = MemoryManager()
            status = manager.status()
            wiring = read_json(manager.state_home / "phasezero/ai/memory-integrations.json", {})
            clients = {c["client"]: c for c in wiring.get("clients", [])}
            return {"available": status.get("serverReachable") is True,
                    "state": status.get("state"), "clients": clients}
        except Exception:
            return {"available": False, "state": "unavailable", "clients": {}}

    def status(self):
        memory = self.memory()
        agents = []
        for agent, spec in self.policy["agents"].items():
            row = self.row(agent)
            wiring = memory["clients"].get(spec["memoryClient"], {})
            row["memory"] = {"required": True, "connected": bool(memory["available"] and wiring.get("mcp")),
                             "hooks": wiring.get("hooks"), "source": "native-service-and-wiring-receipt",
                             "sessionUse": "unverified"}
            agents.append(row)
        reviewed = date.fromisoformat(self.policy["reviewedAt"])
        age = max(0, (datetime.now(timezone.utc).date() - reviewed).days)
        return {"schemaVersion": 1, "ok": True, "state": "ready" if self.project else "needs-project",
                "project": str(self.project) if self.project else None, "agents": agents,
                "defaultProfile": "basic", "memoryRequired": True,
                "rtk": {"installed": bool(shutil.which("rtk")), "sessionUse": "unverified"},
                "review": {"reviewedAt": self.policy["reviewedAt"], "stale": age >= self.policy["reviewAfterDays"],
                           "components": self.policy["components"]},
                "measurements": self.record().get("measurements", {}),
                "usage": self.usage_summary(), "providerCallsMade": False,
                "experimental": {"headroom": "blocked-pending-route-auth-and-memory-homologation",
                                 "pinnedVersion": self.policy["headroomVersion"]}}

    def review(self):
        result = self.status()
        tools = {}
        for name in ("rtk", "headroom"):
            executable = shutil.which(name)
            version = ""
            if executable:
                try:
                    completed = capture([executable, "--version"], timeout=5)
                    if not completed.returncode:
                        version = completed.stdout.decode(errors="replace").strip().splitlines()[0][:100]
                except (EconomyError, IndexError):
                    pass
            tools[name] = {"installed": bool(executable), "version": version,
                           "runtimeValidation": "unverified", "observedAt": stamp()}
        detected = re.search(r"\d+\.\d+\.\d+[A-Za-z0-9.+-]*", tools["headroom"]["version"])
        tools["headroom"]["matchesTestedVersion"] = bool(detected and detected.group() == self.policy["headroomVersion"])
        result["review"]["tools"] = tools
        result["review"]["mcpDefinitions"] = [
            {"id": path.stem, "auto": bool(read_json(path, {}).get("auto", False)), "health": "unverified"}
            for path in sorted((ROOT / "assets/mcp/servers").glob("*.json"))]
        return result

    def plan(self, agent, profile):
        if profile not in self.policy["profiles"]:
            raise EconomyError("unknown-profile")
        target = self.target(agent)
        text = native_text(target)
        old = extract(text, agent)
        saved = self.record().get("agents", {}).get(agent)
        if saved and (old is None or sha(old) != saved["blockHash"]):
            raise EconomyError("profile-drift-review-required")
        if old and not saved and old not in {block(agent, p, self.policy) for p in self.policy["profiles"]}:
            raise EconomyError("unregistered-managed-block-review-required")
        return {"ok": True, "state": "planned", "project": str(self.project), "agent": agent,
                "profile": profile, "path": str(target), "memoryRequired": True,
                "changes": ["additive-native-instructions", "preserve-memory-and-user-rules"],
                "routingChanges": False, "providerCallsMade": False,
                "instruction": block(agent, profile, self.policy)}

    def apply(self, agent, profile):
        with locked(self.state / "operation.lock"):
            self.registry = read_json(self.state / "profiles.json", {"schemaVersion": 1, "projects": {}})
            plan = self.plan(agent, profile)
            target = self.target(agent)
            text = native_text(target)
            original = text
            old = extract(text, agent)
            new = plan["instruction"]
            # Native rule loaders expect these headers only on new dedicated files.
            if not text and agent in {"cursor", "windsurf"}:
                text = "---\ndescription: PhaseZero token profile\n" + ("alwaysApply: true" if agent == "cursor" else "trigger: always_on") + "\n---\n"
            updated = text.replace(old, new) if old else text + ("\n" if text.endswith("\n") else "\n\n" if text else "") + new + "\n"
            before = native_text(target)
            if before != original:
                raise EconomyError("source-changed-during-apply-review-required")
            previous = target.exists()
            if updated != before:
                backup_file(target, module="token-economy")
                atomic(target, updated.encode())
            try:
                project = self.registry["projects"].setdefault(self.project_id, {"path": str(self.project), "agents": {}})
                project["agents"][agent] = {"profile": profile, "blockHash": sha(new), "configuredAt": stamp()}
                self.registry["lastProject"] = str(self.project)
                write_json(self.state / "profiles.json", self.registry)
            except Exception:
                if updated != before:
                    if previous:
                        atomic(target, before.encode())
                    else:
                        target.unlink()
                raise
            ledger_record(module="token-economy", action="apply-profile", modified=[str(target)] if updated != before else [], reversible=True)
            return {"ok": True, "state": "configured", "agent": agent, "profile": profile,
                    "changed": updated != before, "memoryRequired": True, "sessionUse": "unverified", "routingChanges": False}

    def measure(self, agent):
        self.target(agent)
        rtk = shutil.which("rtk")
        if not rtk:
            raise EconomyError("rtk-missing")
        revision = capture(["git", "rev-parse", "HEAD"], cwd=self.project)
        if revision.returncode:
            raise EconomyError("measurement-requires-git-project")
        before = capture(["git", "status", "--porcelain"], cwd=self.project)
        results = []
        for arguments in (("status",), ("log", "-5"), ("diff", "--stat")):
            started = time.monotonic()
            raw = capture(["git", *arguments], cwd=self.project)
            filtered = capture([rtk, "git", *arguments], cwd=self.project)
            if raw.returncode or filtered.returncode:
                raise EconomyError("measurement-command-failed")
            results.append({"command": "git " + " ".join(arguments), "rawBytes": len(raw.stdout),
                            "filteredBytes": len(filtered.stdout), "elapsedMs": round((time.monotonic() - started) * 1000)})
        raw = sum(r["rawBytes"] for r in results)
        filtered = sum(r["filteredBytes"] for r in results)
        after = capture(["git", "status", "--porcelain"], cwd=self.project)
        final_revision = capture(["git", "rev-parse", "HEAD"], cwd=self.project)
        if before.returncode or after.returncode or final_revision.returncode or before.stdout != after.stdout or revision.stdout != final_revision.stdout:
            raise EconomyError("project-changed-during-measurement-retry")
        version = capture([rtk, "--version"])
        report = {"kind": "local-command-output", "observedAt": stamp(), "agent": agent,
                  "profile": self.row(agent)["profile"], "revision": revision.stdout.decode().strip(),
                  "rawBytes": raw, "filteredBytes": filtered, "estimatedRawTokens": math.ceil(raw / 4),
                  "estimatedFilteredTokens": math.ceil(filtered / 4),
                  "reductionPercent": round(100 * (raw - filtered) / raw, 2) if raw else None,
                  "quality": "not-evaluated", "billingSavings": None, "providerCallsMade": False,
                  "scope": "fixed-local-commands-not-agent-session", "commands": results}
        report["rtkVersion"] = version.stdout.decode(errors="replace").strip()[:100] if not version.returncode else "unknown"
        report["workingTreeFingerprint"] = hashlib.sha256(before.stdout).hexdigest()
        with locked(self.state / "operation.lock"):
            self.registry = read_json(self.state / "profiles.json", {"schemaVersion": 1, "projects": {}})
            project = self.registry["projects"].setdefault(self.project_id, {"path": str(self.project), "agents": {}})
            project.setdefault("measurements", {})[agent] = report
            write_json(self.state / "profiles.json", self.registry)
        return {"ok": True, "state": "measured-local-output", "measurement": report}

    def record_usage(self, path):
        safe_path(path)
        if path.stat().st_size > MAX_FILE:
            raise EconomyError("usage-file-too-large")
        value = json.loads(path.read_text(encoding="utf-8"))
        required = {"agent", "profile", "taskId", "acceptanceId", "model", "runtimeVersion", "revision", "inputTokens",
                    "outputTokens", "cachedInputTokens", "latencyMs", "retries", "passed", "source"}
        if not isinstance(value, dict) or set(value) != required:
            raise EconomyError("usage-expects-metadata-only-schema")
        if value["agent"] not in self.policy["agents"] or value["profile"] not in {"basic", "economy"}:
            raise EconomyError("invalid-usage-profile")
        for key in ("inputTokens", "outputTokens", "cachedInputTokens", "latencyMs", "retries"):
            if type(value[key]) is not int or not 0 <= value[key] <= 10**12:
                raise EconomyError("invalid-usage-number")
        if value["cachedInputTokens"] > value["inputTokens"] or type(value["passed"]) is not bool:
            raise EconomyError("invalid-usage-acceptance-or-cache")
        for key in ("taskId", "acceptanceId", "model", "runtimeVersion", "revision"):
            if not isinstance(value[key], str) or not re.fullmatch(r"[A-Za-z0-9_.:/+-]{1,120}", value[key]):
                raise EconomyError("usage-identifiers-only")
        if value["source"] not in {"provider-export", "manual"}:
            raise EconomyError("invalid-usage-source")
        if not self.project:
            raise EconomyError("project-required")
        with locked(self.state / "operation.lock"):
            destination = self.state / "usage" / self.project_id / (sha(json.dumps(value, sort_keys=True)) + ".json")
            write_json(destination, {**value, "importedAt": stamp(), "verification": "reported-not-attested"})
        return {"ok": True, "state": "usage-recorded", "verification": "reported-not-attested"}

    def usage_summary(self):
        groups = {}
        paths = sorted((self.state / "usage" / str(self.project_id)).glob("*.json"))
        for path in paths[:2000]:
            value = read_json(path)
            key = tuple(value[k] for k in ("agent", "taskId", "acceptanceId", "model", "runtimeVersion", "revision"))
            group = groups.setdefault(key, {})
            # Multiple observations require explicit disambiguation; never pick a winning run.
            group.setdefault(value["profile"], []).append(value)
        pairs = []
        for key, group in groups.items():
            if len(group.get("basic", [])) != 1 or len(group.get("economy", [])) != 1:
                continue
            a, b = group["basic"][0], group["economy"][0]
            baseline, optimized = a["inputTokens"] + a["outputTokens"], b["inputTokens"] + b["outputTokens"]
            pairs.append({"agent": key[0], "taskId": key[1], "acceptanceId": key[2], "accepted": a["passed"] and b["passed"],
                          "baselineTokens": baseline, "economyTokens": optimized,
                          "retryRegression": b["retries"] > a["retries"],
                          "baselineLatencyMs": a["latencyMs"], "economyLatencyMs": b["latencyMs"],
                          "baselineCachedInputTokens": a["cachedInputTokens"], "economyCachedInputTokens": b["cachedInputTokens"]})
        by_agent = {}
        for agent in {p["agent"] for p in pairs}:
            rows = [p for p in pairs if p["agent"] == agent]
            baseline = sum(p["baselineTokens"] for p in rows)
            optimized = sum(p["economyTokens"] for p in rows)
            by_agent[agent] = {"pairs": len(rows), "acceptedPairs": sum(p["accepted"] for p in rows),
                               "baselineTokens": baseline, "economyTokens": optimized,
                               "reductionPercent": round(100 * (baseline - optimized) / baseline, 2) if baseline else None,
                               "retryRegressions": sum(p["retryRegression"] for p in rows),
                               "baselineLatencyMs": sum(p["baselineLatencyMs"] for p in rows),
                               "economyLatencyMs": sum(p["economyLatencyMs"] for p in rows)}
        return {"pairs": pairs, "byAgent": by_agent, "truncated": len(paths) > 2000, "billingSavings": None, "automaticPromotion": False,
                "verification": "reported-not-attested", "cost": "requires-provider-billing-and-cache-rates"}


def main(argv=None):
    parser = argparse.ArgumentParser(prog="pz ai token-economy")
    parser.add_argument("action", nargs="?", default="status", choices=("status", "plan", "apply", "reset", "measure", "record", "review"))
    parser.add_argument("--project")
    parser.add_argument("--agent", default="codex")
    parser.add_argument("--profile", default="basic", choices=("basic", "economy"))
    parser.add_argument("--path", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        owner = Economy(args.project)
        if args.action == "status":
            result = owner.status()
        elif args.action == "review":
            result = owner.review()
        elif args.action == "plan":
            result = owner.plan(args.agent, args.profile)
        elif args.action in {"apply", "reset"}:
            result = owner.apply(args.agent, "basic" if args.action == "reset" else args.profile)
        elif args.action == "measure":
            result = owner.measure(args.agent)
        else:
            if not args.path:
                raise EconomyError("usage-file-required")
            result = owner.record_usage(args.path)
    except (EconomyError, OSError, ValueError, RuntimeError) as error:
        reason = str(error) if isinstance(error, EconomyError) else "operation-failed-preserve-state"
        result = {"ok": False, "state": "blocked", "reason": reason}
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
