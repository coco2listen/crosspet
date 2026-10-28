"""来源字段只增元数据，不改变 dev 的门禁、文件路径和角色路由。"""
import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HOOK = Path(__file__).resolve().parent.parent / 'integrations/crosspet-hook.py'
namespace = {'Path': Path}
module = ast.parse(HOOK.read_text())
exec(compile(ast.Module(body=[node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == 'client_from_evidence'], type_ignores=[]), str(HOOK), 'exec'), namespace)
classify = namespace['client_from_evidence']


class ClientSourceTest(unittest.TestCase):
    def test_claude_only_explicit_entrypoint(self):
        for entry, want in [('claude-desktop', 'desktop'), ('cli', 'tui'), ('sdk-cli', 'tui'), ('', 'unknown'), ('desktop', 'unknown')]:
            self.assertEqual(classify('claude', entry, ['/Applications/Claude.app/Contents/MacOS/Claude'])[0], want)

    def test_codex_executable_ancestry(self):
        self.assertEqual(classify('gpt', '', ['/opt/bin/codex'])[0], 'tui')
        self.assertEqual(classify('gpt', '', ['/Applications/ChatGPT.app/Contents/Resources/codex'])[0], 'tui')
        self.assertEqual(classify('gpt', '', ['/Applications/ChatGPT.app/Contents/Resources/codex', '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'])[0], 'desktop')
        self.assertEqual(classify('gpt', '', ['/opt/bin/codex', '/Applications/Codex.app/Contents/MacOS/Codex'])[0], 'desktop')
        self.assertEqual(classify('gpt', '', ['/opt/bin/codex', '/Applications/CrossPet.app/Contents/MacOS/CrossPet'])[0], 'unknown')
        self.assertEqual(classify('gpt', '', ['/opt/bin/node', '/bin/zsh'])[0], 'unknown')
        self.assertEqual(classify('gpt', '', ['/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'])[0], 'unknown')

    def test_dsh_requires_executable_evidence(self):
        self.assertEqual(classify('deepseek', '', [])[0], 'unknown')
        self.assertEqual(classify('deepseek', '', ['/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'])[0], 'desktop')
        self.assertEqual(classify('grok', '', ['/opt/bin/grok'])[0], 'unknown')

    def test_hook_state_sessions_and_turn_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); state = root / 'state'; data = root / 'data'
            data.mkdir(); (data / 'ai-autostart-off').touch()
            env = dict(os.environ, HOME=folder, USERPROFILE=folder, CROSSPET_STATE_DIR=str(state), CROSSPET_DATA_DIR=str(data), CLAUDE_CODE_ENTRYPOINT='cli')
            for key in ('ANTHROPIC_MODEL', 'ANTHROPIC_BASE_URL'):
                env.pop(key, None)
            def send(name, **extra):
                payload = dict(hook_event_name=name, session_id='s1', turn_id='t1', **extra)
                result = subprocess.run([sys.executable, str(HOOK), 'claude'], input=json.dumps(payload), text=True, capture_output=True, env=env, timeout=15)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
                return json.loads((state / 'claude-state.json').read_text())
            first = send('UserPromptSubmit')
            self.assertEqual((first['client'], first['host'], first['session'], first['turn']), ('tui', 'claude', 's1', 't1'))
            card = json.loads((state / 'claude-sessions.json').read_text())['s1']
            self.assertEqual(card['clientReason'], 'entrypoint:cli')
            self.assertEqual(send('SessionStart', source='compact'), first)
            stopped = send('Stop')
            self.assertEqual(send('PreToolUse', tool_name='Read'), stopped)
            self.assertFalse((state / 'clients').exists())
            self.assertFalse((state / 'families').exists())
