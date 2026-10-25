"""Codex 的迟到事件（PR #26 @KQYaili 报的，用例参考了他的测试）：一轮结束（Stop）后，子任务、工具的事件还会陆续到，
上一轮的事件也可能在新的一轮里才到。钩子按「会话 + 轮次（turn_id）」记账，已经结束的轮次的事件直接丢掉，不改状态。
不开真的桌宠、不碰用户配置。
    python3 -m unittest tests.codex_turn_test
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / "integrations" / "crosspet-hook.py"


class CodexTurnTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name, "state")
        self.data = Path(self.tmp.name, "data")
        self.state.mkdir()
        self.data.mkdir()
        (self.data / "ai-autostart-off").write_text("test")

    def tearDown(self):
        self.tmp.cleanup()

    def send(self, name, tid="T1", sid="s1", host="gpt", **extra):
        ev = {"hook_event_name": name, "session_id": sid, "cwd": "/tmp", "model": "gpt-test", "tool_name": "exec_command", **extra}
        if tid is not None:
            ev["turn_id"] = tid
        env = dict(os.environ, CROSSPET_STATE_DIR=str(self.state), CROSSPET_DATA_DIR=str(self.data),
                   CODEX_HOME=str(Path(self.tmp.name, "no-codex")))
        r = subprocess.run([sys.executable, str(HOOK), host], input=json.dumps(ev).encode(), capture_output=True, env=env, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.state / f"{host}-state.json"
        s = json.loads(p.read_text(encoding="utf-8-sig")) if p.exists() else {}
        return s.get("pose"), s.get("event")

    def test_late_events_after_stop_are_dropped(self):
        self.send("UserPromptSubmit")
        self.send("PreToolUse")
        self.assertEqual(self.send("Stop"), ("happy", "Stop"))
        for late in ("PostToolUse", "PreToolUse", "SubagentStart", "SubagentStop"):
            with self.subTest(late=late):
                self.assertEqual(self.send(late), ("happy", "Stop"))

    def test_old_turn_cannot_overwrite_new_turn(self):
        self.send("UserPromptSubmit")
        self.send("Stop")
        self.send("UserPromptSubmit", tid="T2")
        self.assertEqual(self.send("PreToolUse", tid="T2"), ("running", "PreToolUse"))
        self.assertEqual(self.send("PostToolUse", tid="T1"), ("running", "PreToolUse"))   # 上一轮迟到的
        self.assertEqual(self.send("Stop", tid="T2")[1], "Stop")

    def test_superseded_turn_without_stop_is_dropped(self):
        # 上一轮没收到结束事件就开始了新一轮：上一轮迟到的事件也不能盖掉新一轮
        self.send("UserPromptSubmit")
        self.send("PreToolUse")
        self.send("UserPromptSubmit", tid="T2")
        self.assertEqual(self.send("PreToolUse", tid="T2", tool_name="apply_patch")[0], "writing")
        self.assertEqual(self.send("PostToolUse", tid="T1")[0], "writing")

    def test_interrupt_stays_finished(self):
        self.send("UserPromptSubmit")
        self.assertEqual(self.send("Interrupt"), ("surprised", "Stop"))
        self.assertEqual(self.send("SubagentStop"), ("surprised", "Stop"))

    def test_subagent_follows_root_turn(self):
        child = dict(tid="C1", agent_id="child-1")
        self.send("UserPromptSubmit")
        self.send("PreToolUse", tool_name="spawn_agent")
        self.assertEqual(self.send("UserPromptSubmit", **child)[1], "SubagentStart")   # 子任务的第一条消息不算你发了消息
        self.assertEqual(self.send("PreToolUse", **child)[0], "running")
        self.assertEqual(self.send("Stop", **child)[1], "SubagentStop")                 # 子任务停了不等于这一轮结束
        self.assertEqual(self.send("Stop")[1], "Stop")

    def test_subagent_after_root_stop_is_dropped(self):
        child = dict(tid="C1", agent_id="child-1")
        self.send("UserPromptSubmit")
        self.send("Stop")
        for late in ("SubagentStart", "UserPromptSubmit", "PreToolUse", "SubagentStop"):
            with self.subTest(late=late):
                self.assertEqual(self.send(late, **child), ("happy", "Stop"))
        self.assertEqual(self.send("UserPromptSubmit", tid="T2"), ("listening", "UserPromptSubmit"))

    def test_manual_compact_is_its_own_turn(self):
        self.send("UserPromptSubmit")
        self.send("Stop")
        self.assertEqual(self.send("PreCompact", tid="K1", trigger="manual")[0], "compact")
        self.assertEqual(self.send("PostCompact", tid="K1", trigger="manual"), ("happy", "Stop"))
        self.assertEqual(self.send("SubagentStop", tid="T1"), ("happy", "Stop"))

    def test_turn_seen_first_mid_way_is_accepted(self):
        # 钩子刚装上、或者桌宠刚开：第一条就是一轮中间的事件，照常演
        self.assertEqual(self.send("PreToolUse", tid="T9")[0], "running")

    def test_sessions_are_independent(self):
        self.send("UserPromptSubmit", sid="a")
        self.send("Stop", sid="a")
        self.send("UserPromptSubmit", sid="b", tid="B1")
        self.assertEqual(self.send("PreToolUse", sid="b", tid="B1")[0], "running")

    def test_events_without_turn_id_respect_local_completion_fence(self):
        # 无 provider turn_id 也保持完成；只有明确的主会话新输入才能重新打开。
        self.send("UserPromptSubmit", tid=None, host="claude")
        self.send("Stop", tid=None, host="claude")
        self.assertEqual(self.send("PostToolUse", tid=None, host="claude"), ("happy", "Stop"))
        self.assertEqual(self.send("SubagentStop", tid=None, host="claude"), ("happy", "Stop"))
        self.assertEqual(self.send("UserPromptSubmit", tid=None, host="claude")[0], "listening")
        self.assertEqual(self.send("SubagentStop", tid=None, host="claude")[0], "thinking")
        self.assertEqual(self.send("PreToolUse", tid=None, host="claude")[0], "running")


if __name__ == "__main__":
    unittest.main()
