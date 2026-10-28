"""多宠旁路仅显式开启；门禁保持 dev 的会话轮次规则。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
HOOK = Path(__file__).resolve().parent.parent / 'integrations/crosspet-hook.py'

class ClientOutputTest(unittest.TestCase):
    def test_enabled_closed_late_restart_and_disabled(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); state = root / 'state'; data = root / 'data'; data.mkdir()
            (data / 'ai-autostart-off').touch(); marker = data / 'multi-pets-enabled'
            env = dict(os.environ, HOME=folder, USERPROFILE=folder, CROSSPET_STATE_DIR=str(state), CROSSPET_DATA_DIR=str(data), CLAUDE_CODE_ENTRYPOINT='cli')
            for key in ('ANTHROPIC_MODEL', 'ANTHROPIC_BASE_URL'): env.pop(key, None)
            def send(name, **extra):
                result = subprocess.run([sys.executable, str(HOOK), 'claude'], input=json.dumps(dict(hook_event_name=name, session_id='s1', **extra)), text=True, capture_output=True, env=env, timeout=15)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
            send('UserPromptSubmit'); self.assertFalse((state/'families').exists())
            marker.touch(); send('UserPromptSubmit')
            path = state/'families/claude'/('claude-code-tui-'+hashlib.sha256(b's1').hexdigest()[:20]+'.json')
            active = json.loads(path.read_text()); self.assertEqual(active['status'], 'Thinking')
            send('Stop'); ended = path.read_bytes(); self.assertEqual(json.loads(ended)['status'], 'Success')
            send('PreToolUse', tool_name='Read'); self.assertEqual(path.read_bytes(), ended)
            send('SessionEnd'); self.assertEqual(json.loads(path.read_bytes())['status'], 'Offline')
            send('UserPromptSubmit'); self.assertEqual(json.loads(path.read_bytes())['status'], 'Thinking')
            marker.unlink(); before=path.read_bytes(); send('Stop'); self.assertEqual(path.read_bytes(), before)

    def test_explicit_turn_late_does_not_publish(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); data=root/'data'; data.mkdir(); (data/'ai-autostart-off').touch(); (data/'multi-pets-enabled').touch()
            env=dict(os.environ, HOME=folder, USERPROFILE=folder, CROSSPET_STATE_DIR=str(root/'state'), CROSSPET_DATA_DIR=str(data), CLAUDE_CODE_ENTRYPOINT='cli')
            for name in ('UserPromptSubmit','Stop','PreToolUse'):
                payload=dict(hook_event_name=name,session_id='s1',turn_id='t1',tool_name='Read')
                result=subprocess.run([sys.executable,str(HOOK),'claude'],input=json.dumps(payload),text=True,capture_output=True,env=env,timeout=15)
                self.assertEqual(result.returncode,0)
                path=next((root/'state/families/claude').glob('*.json'))
                if name=='Stop': ended=path.read_bytes()
                if name=='PreToolUse': self.assertEqual(path.read_bytes(),ended)

    def test_wall_clock_rollback_recovers_only_for_proven_new_root(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); data=root/'data'; data.mkdir(); (data/'ai-autostart-off').touch(); (data/'multi-pets-enabled').touch()
            env=dict(os.environ, HOME=folder, USERPROFILE=folder, CROSSPET_STATE_DIR=str(root/'state'), CROSSPET_DATA_DIR=str(data), CLAUDE_CODE_ENTRYPOINT='cli')
            for key in ('ANTHROPIC_MODEL', 'ANTHROPIC_BASE_URL'): env.pop(key, None)
            def send(name, turn):
                result=subprocess.run([sys.executable,str(HOOK),'claude'],input=json.dumps(dict(hook_event_name=name,session_id='s1',turn_id=turn,tool_name='Read')),text=True,capture_output=True,env=env,timeout=15)
                self.assertEqual((result.returncode,result.stdout,result.stderr),(0,'',''))
            send('UserPromptSubmit','t1')
            path=next((root/'state/families/claude').glob('*.json'))
            first=json.loads(path.read_text()); first['observedAt']+=3600; first['ts']+=3600
            path.write_text(json.dumps(first)); future=path.read_bytes()
            send('PreToolUse','t1'); self.assertEqual(path.read_bytes(),future)
            send('UserPromptSubmit','t2'); restored=json.loads(path.read_text())
            self.assertEqual(restored['turnId'],'t2'); self.assertGreater(restored['sequence'],first['sequence']); self.assertLess(restored['observedAt'],first['observedAt'])
            send('Stop','t2'); ended=path.read_bytes()
            send('UserPromptSubmit','t1'); self.assertEqual(path.read_bytes(),ended)
