#!/usr/bin/env python3
"""Cross-process five-client E2E: real hook subprocesses -> state files -> isolated CrossPet (5 pets) -> rendered badge.

Claude clients are identified by CLAUDE_CODE_ENTRYPOINT, Codex clients by a codex ancestor process, DSH by source;
CROSSPET_CLIENT is never used. The app is a real process with real WKWebViews; the *producers* are the repo's hook script
driven with synthetic events, so this is not a real-client run.  usage: clients_e2e.py <CrossPet.app> <evidence.json>
"""
import json, os, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "integrations/crosspet-hook.py"
APP = Path(sys.argv[1]) / "Contents/MacOS/CrossPet"
EVIDENCE = Path(sys.argv[2])
PETS = ["claude-tui", "claude-desktop", "codex-tui", "codex-desktop", "dsh-desktop"]
tmp = Path(tempfile.mkdtemp(prefix="crosspet-e2e."))
SUITE = f"io.github.crosspet.test.e2e.{os.getpid()}"
for sub in ("home", "data", "state"):
    (tmp / sub).mkdir()
(tmp / "data/ai-autostart-off").touch()
TRACE = tmp / "trace.jsonl"
subprocess.run(["defaults", "write", SUITE, "petMode", "-string", "clients"], check=True)
for i, pet in enumerate(PETS):  # distinct places so nothing overlaps; irrelevant to the assertions
    subprocess.run(["defaults", "write", f"{SUITE}.pet.{pet}", "origin", "-array", str(40 + i * 230), "120"], check=True)
    subprocess.run(["defaults", "write", f"{SUITE}.pet.{pet}", "size", "-float", "0.6"], check=True)
for name, rel in (("codex-desktop", "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"), ("codex-tui", "bin/codex")):
    shim = tmp / "shim" / name / rel
    shim.parent.mkdir(parents=True)
    shim.write_text('#!/bin/sh\n"$@"\nexit $?\n')
    shim.chmod(0o755)

env = dict(os.environ, CFFIXED_USER_HOME=str(tmp / "home"), CROSSPET_PREFERENCES_SUITE=SUITE, CROSSPET_DATA_DIR=str(tmp / "data"),
           CROSSPET_STATE_DIR=str(tmp / "state"), CROSSPET_RENDER_TRACE=str(TRACE))
for name in ("CROSSPET_CLIENT", "CLAUDE_CODE_ENTRYPOINT"):
    env.pop(name, None)
results = []
proc = None


def check(name, ok, detail=""):
    results.append({"name": name, "passed": bool(ok), "detail": str(detail)})
    print("PASS" if ok else "FAIL", name, detail)


def launch():
    global proc
    proc = subprocess.Popen([str(APP)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(7)


def send(client, event, sid, **extra):
    """client: claude-tui | claude-desktop | codex-tui | codex-desktop | dsh-desktop"""
    payload = json.dumps(dict(hook_event_name=event, session_id=sid, cwd="/tmp", **extra))
    run_env = dict(env)
    if client.startswith("claude"):
        run_env["CLAUDE_CODE_ENTRYPOINT"] = "cli" if client.endswith("tui") else "claude-desktop"
        cmd, host = [sys.executable, str(HOOK), "claude"], "claude"
    elif client.startswith("codex"):
        cmd, host = [str(tmp / "shim" / client / ("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" if client.endswith("desktop") else "bin/codex")), sys.executable, str(HOOK), "gpt"], "gpt"
    else:
        cmd, host = [sys.executable, str(HOOK), "deepseek"], "deepseek"
    subprocess.run(cmd, input=payload, text=True, capture_output=True, env=run_env, timeout=15, check=True)


def rows(pet):
    out = []
    if TRACE.exists():
        for line in TRACE.read_text().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("pet") == pet and "kind" not in row:
                out.append(row)
    return out


def badge(pet):
    r = rows(pet)
    return r[-1]["badge"] if r else None


def settle(seconds=1.4):
    time.sleep(seconds)


try:
    launch()
    for pet in PETS:
        check(f"no_events_is_not_offline_{pet}", badge(pet) == "等待会话事件", badge(pet))
    # S1: each client's first event reaches only its own pet.
    for client in PETS:
        send(client, "UserPromptSubmit", "shared-id", model="x", turn_id="t1")
    settle()
    for pet in PETS:
        check(f"own_event_routed_{pet}", (badge(pet) or "").startswith("Thinking"), badge(pet))
    # S2: same session id in tui and desktop is two sessions; a tool event on tui does not touch desktop.
    n_desktop = len(rows("claude-desktop"))
    send("claude-tui", "PreToolUse", "shared-id", tool_name="Read"); settle()
    check("tui_tool_running", (badge("claude-tui") or "").startswith("Tool Running"), badge("claude-tui"))
    check("desktop_unchanged_by_tui_event", len(rows("claude-desktop")) == n_desktop and (badge("claude-desktop") or "").startswith("Thinking"))
    # S3: concurrency inside one pet - a permission wait outranks other work, then yields when answered.
    send("claude-desktop", "UserPromptSubmit", "other", turn_id="t9")
    send("claude-desktop", "Notification", "shared-id", notification_type="permission_prompt"); settle()
    check("permission_outranks_work", (badge("claude-desktop") or "").startswith("Waiting Permission"), badge("claude-desktop"))
    send("claude-desktop", "PostToolUse", "shared-id", tool_name="Bash"); settle()
    check("permission_clears_to_work", (badge("claude-desktop") or "").startswith(("Thinking", "Tool Running")), badge("claude-desktop"))
    # S4: duplicate delivery of the same event id is not a second transition.
    before = len(rows("codex-tui"))
    send("codex-tui", "PreToolUse", "shared-id", tool_name="Read", event_id="dup-1"); settle()
    after_first = len(rows("codex-tui"))
    send("codex-tui", "PreToolUse", "shared-id", tool_name="Read", event_id="dup-1"); settle()
    check("duplicate_event_ignored", after_first > before and len(rows("codex-tui")) == after_first)
    # S5/S6: completion and error, Success relaxes to Idle after the display window.
    send("codex-desktop", "Stop", "shared-id", turn_id="t1"); settle()
    check("success_shown", (badge("codex-desktop") or "").startswith("Success"), badge("codex-desktop"))
    time.sleep(5)
    check("success_relaxes_to_idle", (badge("codex-desktop") or "").startswith("Idle"), badge("codex-desktop"))
    send("claude-tui", "StopFailure", "shared-id", turn_id="t1"); settle()
    check("error_shown", (badge("claude-tui") or "").startswith("Error"), badge("claude-tui"))
    # S7: a DSH event whose model is Claude/GPT stays on the DSH pet.
    n = {pet: len(rows(pet)) for pet in PETS if pet != "dsh-desktop"}
    send("dsh-desktop", "PreToolUse", "dsh-1", model="claude-sonnet-5-5", tool_name="Read"); settle()
    check("dsh_claude_model_stays_on_dsh", all(len(rows(p)) == n[p] for p in n) and (badge("dsh-desktop") or "").startswith("Tool Running"))
    # S8: SessionEnd is the only offline evidence.
    send("dsh-desktop", "SessionEnd", "dsh-1"); send("dsh-desktop", "SessionEnd", "shared-id"); settle()
    check("session_end_is_offline", (badge("dsh-desktop") or "").startswith("Offline"), badge("dsh-desktop"))
    # S9: a producer that cannot identify its client is surfaced, never guessed into a pet.
    env_unknown = dict(env); env_unknown.pop("CLAUDE_CODE_ENTRYPOINT", None)
    subprocess.run([sys.executable, str(HOOK), "claude"], input=json.dumps(dict(hook_event_name="UserPromptSubmit", session_id="mystery", cwd="/tmp")),
                   text=True, capture_output=True, env=env_unknown, timeout=15, check=True)
    settle()
    check("unknown_client_surfaced", "未识别" in (badge("claude-tui") or "") and "未识别" in (badge("claude-desktop") or ""), badge("claude-tui"))
    last = {pet: badge(pet) for pet in PETS}
    # S10: crash + restart restores from files without inventing results.
    proc.send_signal(signal.SIGKILL); proc.wait(); time.sleep(1)
    TRACE.unlink()
    launch()
    check("restart_keeps_claude_desktop_state", (badge("claude-desktop") or "").startswith(("Thinking", "Waiting", "Tool")), badge("claude-desktop"))
    check("restart_does_not_invent_success", not any((badge(p) or "").startswith("Success") for p in PETS))
    check("restart_app_alive", proc.poll() is None)
    # A completed turn without a provider turn ID must survive delayed child/tool hooks.
    send("claude-tui", "UserPromptSubmit", "completion-fence")
    send("claude-tui", "Stop", "completion-fence")
    send("claude-tui", "SubagentStop", "completion-fence")
    send("claude-tui", "PostToolUse", "completion-fence", tool_name="Read")
    settle()
    check("late_hooks_do_not_revive_completed_turn", (badge("claude-tui") or "").startswith("Success"), badge("claude-tui"))
    send("claude-tui", "UserPromptSubmit", "completion-fence")
    send("claude-tui", "PreToolUse", "completion-fence", tool_name="Read")
    settle()
    check("explicit_new_prompt_reopens_work", (badge("claude-tui") or "").startswith("Tool Running"), badge("claude-tui"))
    # The same session's explicit client evidence resolves its old unknown warning.
    send("claude-tui", "SessionEnd", "mystery")
    old = dict(schema=1, family="claude", source="claude-code", client="tui", sessionId="old-thinking",
               model="test", status="Thinking", pose="thinking", event="SubagentStop", sequence=1,
               ts=time.time()-3600, observedAt=time.time()-3600)
    folder=tmp / "state/families/claude"
    (folder / "historical-thinking.json").write_text(json.dumps(old))
    old.update(client="unknown", sessionId="historical-unknown",status="Offline",pose="sleeping",event="SessionEnd")
    (folder / "historical-unknown.json").write_text(json.dumps(old))
    send("claude-tui", "Stop", "completion-fence")
    settle(5)
    check("old_thinking_does_not_obscure_completed_task", (badge("claude-tui") or "").startswith("Idle"), badge("claude-tui"))
    check("historical_and_resolved_unknown_warnings_disappear", "未识别" not in (badge("claude-tui") or ""), badge("claude-tui"))

finally:
    if proc and proc.poll() is None:
        proc.terminate(); proc.wait()
    for domain in [SUITE] + [f"{SUITE}.pet.{p}" for p in PETS]:
        subprocess.run(["defaults", "delete", domain], capture_output=True)
    shutil.rmtree(tmp, ignore_errors=True)
failed = [r for r in results if not r["passed"]]
EVIDENCE.write_text(json.dumps({"kind": "producer_subprocess_to_real_app", "passed": not failed, "assertions": results,
    "limitations": ["synthetic events through the repo hook script, not real client sessions", "badge text read from the page via render trace"]}, indent=2, ensure_ascii=False))
print("ALL PASSED" if not failed else f"{len(failed)} FAILED", len(results))
sys.exit(1 if failed else 0)
