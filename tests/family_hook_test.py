"""Real hook subprocess routing plus controlled process fixtures for client identity."""
import ast
import shutil
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from types import SimpleNamespace
from concurrent.futures import ThreadPoolExecutor

HOOK = Path(__file__).resolve().parents[1] / 'integrations/crosspet-hook.py'

class FamilyHookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'ai-autostart-off').touch()
        self.env = dict(os.environ, CROSSPET_STATE_DIR=str(self.root), CROSSPET_DATA_DIR=str(self.root))
        for name in ('CROSSPET_CLIENT', 'CLAUDE_CODE_ENTRYPOINT'):
            self.env.pop(name, None)  # the suite may itself run inside a Claude Code session

    def tearDown(self):
        self.tmp.cleanup()

    def send(self, host, event, sid='same-session', **extra):
        payload = dict(hook_event_name=event, session_id=sid, cwd='/tmp', **extra)
        result = subprocess.run([sys.executable, str(HOOK), host], input=json.dumps(payload), text=True,
                                capture_output=True, env=self.env, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = list((self.root / 'families' / host).glob('*.json'))
        return [json.loads(p.read_text()) for p in files]

    def test_same_session_different_sources_remains_isolated(self):
        for host in ('claude', 'gpt', 'deepseek'):
            self.env['CROSSPET_CLIENT'] = 'desktop' if host == 'deepseek' else 'tui'
            record = self.send(host, 'PreToolUse', tool_name='Read', model='claude-fake')[0]
            self.assertEqual(record['family'], host)
            self.assertEqual(record['status'], 'Tool Running')
            self.assertEqual(record['client'], 'desktop' if host == 'deepseek' else 'tui')
            self.assertNotIn('pid', record)
        self.assertEqual(len(list((self.root / 'families').rglob('*.json'))), 3)

    def test_claude_client_comes_from_host_entrypoint_only(self):
        for entry, expected in (('claude-desktop', 'desktop'), ('cli', 'tui'), ('sdk-cli', 'tui'), ('vscode', 'unknown'), ('', 'unknown')):
            self.env['CLAUDE_CODE_ENTRYPOINT'] = entry
            records = self.send('claude', 'PreToolUse', sid='s-' + entry, tool_name='Read')
            record = next(r for r in records if r['sessionId'] == 's-' + entry)
            self.assertEqual(record['client'], expected, entry)
            self.assertTrue(record['clientReason'].startswith('entrypoint:'))

    def detect_codex_client(self, table):
        # Execute the production function without running the hook's stdin/file side effects.
        # Controlled ps output excludes whichever Claude/Codex host is running this test suite.
        tree = ast.parse(HOOK.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'detect_client')
        namespace = {'character': 'gpt', 'os': SimpleNamespace(environ={}, name='posix', getpid=lambda: 100)}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(HOOK), 'exec'), namespace)
        with mock.patch.object(subprocess, 'run', return_value=SimpleNamespace(stdout=table)) as ps:
            result = namespace['detect_client']()
        ps.assert_called_once_with(['/bin/ps', '-A', '-o', 'pid=,ppid=,command='], capture_output=True, text=True, timeout=3)
        return result

    def test_codex_client_needs_a_codex_ancestor(self):
        # A model name or an unrelated Desktop process elsewhere in ps is no origin evidence.
        table = "100 90 python3 crosspet-hook.py gpt\n90 1 /bin/zsh\n200 1 /Applications/ChatGPT.app/Contents/Resources/codex\n"
        self.assertEqual(self.detect_codex_client(table), ('unknown', 'no-codex-ancestor'))

    def test_codex_desktop_and_tui_by_host_executable(self):
        for command, expected in [
            ('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex', ('desktop', 'ancestor:ChatGPT.app/codex')),
            ('/opt/homebrew/bin/codex', ('tui', 'ancestor:codex-outside-ChatGPT.app')),
            ('codex', ('tui', 'ancestor:codex-outside-ChatGPT.app')),
            ('node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex', ('tui', 'ancestor:codex-outside-ChatGPT.app')),
        ]:
            with self.subTest(command=command):
                table = f"100 90 python3 crosspet-hook.py gpt\n90 80 /bin/sh\n80 1 {command}\n"
                self.assertEqual(self.detect_codex_client(table), expected)

    def test_explicit_clients_keep_same_session_independent(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        self.send('gpt', 'PreToolUse', turn_id='a')
        self.env['CROSSPET_CLIENT'] = 'desktop'
        records = self.send('gpt', 'Stop', turn_id='a')
        self.assertEqual({r['client'] for r in records}, {'tui', 'desktop'})
        self.assertEqual({r['status'] for r in records}, {'Tool Running', 'Success'})
        self.env['CROSSPET_CLIENT'] = 'tui'
        records = self.send('gpt', 'PreToolUse', turn_id='a', tool_name='Read')
        self.assertEqual(next(r for r in records if r['client'] == 'tui')['sequence'], 2)
        self.assertEqual(next(r for r in records if r['client'] == 'tui')['status'], 'Tool Running')

    def test_semantic_states(self):
        for event, extra, status in [
            ('SessionStart', {}, 'Idle'), ('UserPromptSubmit', {}, 'Thinking'),
            ('PreToolUse', {'tool_name': 'AskUserQuestion'}, 'Waiting Input'),
            ('Notification', {'notification_type': 'permission_prompt'}, 'Waiting Permission'),
            ('Notification', {'notification_type': 'elicitation_dialog'}, 'Waiting Input'),
            ('Notification', {'notification_type': 'agent_needs_input'}, 'Waiting Input'),
            ('PostCompact', {'trigger': 'manual'}, 'Idle'),
            ('Stop', {}, 'Success'), ('StopFailure', {}, 'Error'),
            ('Interrupt', {}, 'Idle'), ('SessionEnd', {}, 'Offline')]:
            with self.subTest(event=event):
                record = self.send('claude', event, **extra)[0]
                self.assertEqual(record['status'], status)

    def test_turn_gate_keeps_completed_turn_finished(self):
        self.send('gpt', 'UserPromptSubmit', turn_id='a')
        self.send('gpt', 'Stop', turn_id='a')
        record = self.send('gpt', 'PreToolUse', turn_id='a', tool_name='exec_command')[0]
        self.assertEqual(record['status'], 'Success')
        self.assertEqual(record['sequence'], 2)

    def test_no_turn_id_terminal_events_fence_late_activity(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        for terminal in ('Stop', 'StopFailure', 'Interrupt', 'SessionEnd'):
            sid = 'fence-' + terminal
            self.send('claude', 'UserPromptSubmit', sid=sid)
            ended = next(r for r in self.send('claude', terminal, sid=sid) if r['sessionId'] == sid)
            for late in ('SubagentStop', 'SubagentStart', 'PostToolUse', 'PreToolUse', 'Notification'):
                records = self.send('claude', late, sid=sid, tool_name='Read', notification_type='permission_prompt')
                self.assertEqual(next(r for r in records if r['sessionId'] == sid), ended, (terminal, late))
            self.assertEqual(ended['turnId'], '')  # local generation is never a claimed provider ID
            legacy = json.loads((self.root / 'claude-state.json').read_text())
            self.assertEqual(legacy['event'], 'Stop' if terminal in ('StopFailure', 'Interrupt') else terminal)

    def test_no_turn_id_root_prompt_reopens_but_child_does_not(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        self.send('claude', 'UserPromptSubmit')
        child = self.send('claude', 'Stop', agent_id='child')[0]
        self.assertEqual((child['event'], child['status']), ('SubagentStop', 'Thinking'))
        self.assertEqual(self.send('claude', 'PreToolUse', tool_name='Read')[0]['status'], 'Tool Running')
        ended = self.send('claude', 'Stop')[0]
        self.assertEqual(self.send('claude', 'UserPromptSubmit', agent_id='late-child')[0], ended)
        self.assertEqual(self.send('claude', 'SessionEnd', agent_id='late-child')[0], ended)
        self.assertEqual(self.send('claude', 'UserPromptSubmit')[0]['status'], 'Thinking')
        self.assertEqual(self.send('claude', 'PreToolUse', tool_name='Read')[0]['status'], 'Tool Running')

    def test_no_turn_id_fences_are_source_client_session_scoped(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        ended = self.send('claude', 'Stop', sid='closed')[0]
        self.assertEqual(next(r for r in self.send('claude', 'PreToolUse', sid='open', tool_name='Read') if r['sessionId'] == 'open')['status'], 'Tool Running')
        gpt = self.send('gpt', 'PreToolUse', sid='closed', tool_name='Read')[0]
        self.assertEqual(gpt['status'], 'Tool Running')
        self.env['CROSSPET_CLIENT'] = 'desktop'
        desktop = next(r for r in self.send('claude', 'PreToolUse', sid='closed', tool_name='Read') if r['client'] == 'desktop')
        self.assertEqual(desktop['status'], 'Tool Running')
        self.env['CROSSPET_CLIENT'] = 'tui'
        self.assertEqual(next(r for r in self.send('claude', 'PostToolUse', sid='closed') if r['client'] == 'tui' and r['sessionId'] == 'closed'), ended)

    def test_no_turn_id_concurrent_late_hooks_preserve_completion(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        ended = self.send('claude', 'Stop')[0]
        with ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda _: self.send('claude', 'SubagentStop')[0], range(12)))
        self.assertTrue(all(record == ended for record in results))
        self.assertEqual(json.loads((self.root / 'claude-state.json').read_text())['event'], 'Stop')

    def test_no_turn_id_manual_compact_can_open_and_close_after_stop(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        self.send('claude', 'Stop')
        self.assertEqual(self.send('claude', 'PreCompact', trigger='manual')[0]['pose'], 'compact')
        finished = self.send('claude', 'PostCompact', trigger='manual')[0]
        self.assertEqual(finished['status'], 'Idle')
        self.assertEqual(self.send('claude', 'SubagentStop')[0], finished)

    def test_no_turn_id_upgrade_restores_fence_from_explicit_end(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        ended = self.send('claude', 'Stop')[0]
        shutil.rmtree(self.root / 'local-turn-fences')
        self.assertEqual(self.send('claude', 'SubagentStop')[0], ended)
        self.assertEqual(self.send('claude', 'UserPromptSubmit')[0]['status'], 'Thinking')

    def test_no_turn_id_upgrade_uses_matching_mod_completion(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        ended = self.send('claude', 'Stop')[0]
        folder = self.root / 'families/claude'
        original = next(folder.glob('*.json'))
        encoded = 'same-session'.encode('utf-16-be').hex()
        mod = folder / ('claude-code-tui-mod-' + encoded + '.json')
        original.rename(mod)
        shutil.rmtree(self.root / 'local-turn-fences')
        self.assertEqual(self.send('claude', 'SubagentStop')[0], ended)
        records = self.send('claude', 'UserPromptSubmit')
        self.assertTrue(any(row['event'] == 'UserPromptSubmit' for row in records))

    def test_no_turn_id_upgrade_does_not_close_newer_live_standard_work(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        current = self.send('claude', 'PreToolUse', tool_name='Read')[0]
        folder = self.root / 'families/claude'
        standard = next(folder.glob('*.json'))
        encoded = 'same-session'.encode('utf-16-be').hex()
        mod = folder / ('claude-code-tui-mod-' + encoded + '.json')
        mod.write_text(json.dumps(dict(current, event='Stop', status='Success', pose='happy', ts=current['ts'] - 10, observedAt=current['observedAt'] - 10, producerId='old-mod')))
        shutil.rmtree(self.root / 'local-turn-fences')
        self.send('claude', 'PostToolUse', tool_name='Read')
        self.assertEqual(json.loads(standard.read_text())['event'], 'PostToolUse')
        self.assertEqual(json.loads(standard.read_text())['status'], 'Thinking')
        self.send('claude', 'PreToolUse', tool_name='Write')
        self.assertEqual(json.loads(standard.read_text())['status'], 'Tool Running')
        self.assertEqual(json.loads(mod.read_text())['status'], 'Success')

    def test_no_turn_id_matching_mod_stop_closes_open_standard_fence(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        current = self.send('claude', 'UserPromptSubmit')[0]
        folder = self.root / 'families/claude'
        standard = next(folder.glob('*.json'))
        encoded = 'same-session'.encode('utf-16-be').hex()
        mod = folder / ('claude-code-tui-mod-' + encoded + '.json')
        now = time.time()
        mod.write_text(json.dumps(dict(current, event='Stop', status='Success', pose='happy', ts=now, observedAt=now, producerId='mod-test')))
        self.send('claude', 'SubagentStop')
        self.assertEqual(json.loads(standard.read_text()), current)
        self.assertEqual(json.loads(mod.read_text())['status'], 'Success')
        self.send('claude', 'UserPromptSubmit')
        self.send('claude', 'PreToolUse', tool_name='Read')
        self.assertEqual(json.loads(standard.read_text())['status'], 'Tool Running')
        self.assertEqual(json.loads(mod.read_text())['status'], 'Success')

    def test_no_turn_id_received_order_protects_new_generation(self):
        tree = ast.parse(HOOK.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'local_turn_gate')
        namespace = {'state_dir': self.root, 'os': os, 'json': json, 'event': {}}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(HOOK), 'exec'), namespace)
        gate = namespace['local_turn_gate']
        def admit(event, observed):
            allowed, handle = gate('claude-tui', 'ordered', event, False, observed)
            if handle is not None:
                handle.close()
            return allowed
        self.assertTrue(admit('UserPromptSubmit', 100))
        self.assertTrue(admit('Stop', 102))
        self.assertFalse(admit('SubagentStop', 101))
        self.assertFalse(admit('UserPromptSubmit', 101))
        self.assertTrue(admit('UserPromptSubmit', 103))
        self.assertFalse(admit('Stop', 102.5))
        self.assertTrue(admit('PreToolUse', 104))
        book = json.loads(next((self.root / 'local-turn-fences').glob('*.json')).read_text())
        self.assertEqual(book['generation'], 2)
        self.assertFalse(book['closed'])

    def test_snapshot_excludes_private_payload(self):
        record = self.send('claude', 'PreToolUse', tool_name='Read', tool_input={'secret': 'DO-NOT-STORE'}, message='PRIVATE')[0]
        self.assertNotIn('DO-NOT-STORE', json.dumps(record))
        self.assertNotIn('PRIVATE', json.dumps(record))

    def test_duplicate_id_does_not_advance_sequence(self):
        a = self.send('claude', 'PreToolUse', event_id='one')[0]
        b = self.send('claude', 'PreToolUse', event_id='one')[0]
        self.assertEqual(a, b)

    def test_sessions_have_independent_snapshots(self):
        self.send('gpt', 'PreToolUse', sid='a', tool_name='Read')
        records = self.send('gpt', 'Stop', sid='b')
        self.assertEqual({r['status'] for r in records}, {'Tool Running', 'Success'})

    def test_explicit_completion_survives_fast_session_end(self):
        result = self.send('claude', 'Stop')[0]
        ended = self.send('claude', 'SessionEnd')[0]
        self.assertEqual(ended['status'], 'Offline')
        self.assertEqual(ended['lastResult']['status'], 'Success')
        self.assertEqual(ended['lastResult']['ts'], result['ts'])
        self.assertEqual(ended['lastResult']['event'], 'Stop')

    def test_quick_tool_preserves_animation_metadata(self):
        before = self.send('claude', 'PreToolUse', tool_name='Read')[0]
        after = self.send('claude', 'PostToolUse', tool_name='Read')[0]
        self.assertEqual(after['status'], 'Thinking')
        self.assertEqual(after['after'], 'reading')
        self.assertEqual(after['afterTs'], before['ts'])
        self.assertNotIn('lastResult', after)

    def test_model_metadata_uses_only_same_source_client_session(self):
        self.env['CROSSPET_CLIENT'] = 'tui'
        self.send('gpt', 'SessionStart', model='actual-a')
        records = self.send('gpt', 'PreToolUse', tool_name='Read')
        self.assertEqual(records[0]['model'], 'actual-a')
        self.env['CROSSPET_CLIENT'] = 'desktop'
        records = self.send('gpt', 'PreToolUse', tool_name='Read')
        self.assertEqual(next(r for r in records if r['client'] == 'desktop')['model'], '')
