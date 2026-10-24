#!/bin/sh
# Gemini（Antigravity）额度排版：先 app/build.sh 编译，再 tests/antigravity_quota_probe.sh
# 样本在 tests/fixtures/antigravity/（只留模型名和额度字段）
set -eu
cd "$(dirname "$0")/.."
BIN=build/CrossPet.app/Contents/MacOS/CrossPet
F=tests/fixtures/antigravity
fail=0
check() {   # 名字 样本 期望（Python 表达式，q 是结果）
  out=$(perl -e 'alarm 5; exec @ARGV' "$BIN" --agy-quota-probe "$F/$2.json" 2>/dev/null || echo '"（没有输出）"')
  python3 - "$1" "$3" "$out" <<'PY' || fail=1
import json, sys
name, expect, out = sys.argv[1:4]
try: q = json.loads(out)
except Exception: q = None
ok = False
try: ok = bool(eval(expect, {"q": q}))
except Exception: pass
print(("PASS" if ok else "FAIL"), name, "" if ok else out)
sys.exit(0 if ok else 1)
PY
}
# 2026-10-14 实测：非 Ultra 账号里「Gemini 4 Argon」标着不可用、额度信息是空的，以前被当成「剩 0%」排在第一行
# 固定两行，和 Antigravity 自己「View Usage」的分组一样：Gemini 一行、Claude/GPT 一行，数字相同也不合并
check "不可用的模型不算进额度" ultra-only-model 'q["text"].split(" ｜ ")[0].startswith("Gemini 剩余 100%") and q["text"].split(" ｜ ")[1] == "Claude/GPT 剩余 100%" and q["low"] is False'
check "真用完了还是 0%" gemini-used-up 'q["text"].startswith("Gemini 剩余 0%") and "重置" in q["text"].split(" ｜ ")[0] and q["text"].split(" ｜ ")[1] == "Claude/GPT 剩余 100%" and q["low"] is True'
check "两个池 + 不可用模型" two-pools-with-unavailable 'q["text"].startswith("Gemini 剩余 52%") and q["text"].split(" ｜ ")[1] == "Claude/GPT 剩余 99%" and " 0%" not in q["text"] and q["low"] is False'
# 主要来源：额度汇总（RetrieveUserQuotaSummary，和 Antigravity 的「View Usage」同一份数据，刚对话完就更新）
check "汇总：两组各一行，98% 是新数据" summary-live 'q["text"].split(" ｜ ")[0].startswith("Gemini 剩余 100%") and "重置" in q["text"].split(" ｜ ")[0] and q["text"].split(" ｜ ")[1].startswith("Claude/GPT 剩余 98% · ") and q["text"].split(" ｜ ")[1].endswith(" 重置") and q["low"] is False'
check "汇总：用完时比例被省略，算 0%" summary-gemini-used-up 'q["text"].startswith("Gemini 剩余 0%") and q["low"] is True'
check "汇总：一组有两个窗口，只留剩余最少的那个" summary-two-windows 'q["text"].split(" ｜ ")[0].startswith("Gemini 今日 剩余 40%") and q["text"].split(" ｜ ")[1].startswith("Claude/GPT 剩余 98% · ") and "本周" not in q["text"]'
check "汇总：独立额度池（Gemini 4 Argon）保留名字，每组一行" summary-multi-pool 'q["text"].split(" ｜ ")[0].startswith("Gemini 本周 剩余 99%") and q["text"].split(" ｜ ")[1].startswith("Gemini 4 Argon 剩余 46% · ") and q["text"].split(" ｜ ")[2].startswith("Claude/GPT") and len(q["text"].split(" ｜ ")) == 3 and "Five Hour" not in q["text"]'
check "汇总：5h 最紧时显示成「5小时」" summary-5h-tightest 'q["text"].split(" ｜ ")[0].startswith("Gemini 5小时 剩余 30%") and q["text"].split(" ｜ ")[1].startswith("Claude/GPT 剩余 100% · ") and "本周" not in q["text"]'
check "汇总：两个窗口一样紧（50%），不管接口顺序都显示 5小时 和它的重置时间" summary-tie-5h-first 'q["text"].split(" ｜ ")[0].startswith("Gemini 5小时 剩余 50% · ") and q["text"].split(" ｜ ")[0].endswith(" 重置")'
check "汇总：同上，周额度排在前面结果一样" summary-tie-weekly-first 'q["text"].split(" ｜ ")[0].startswith("Gemini 5小时 剩余 50% · ")'
check "汇总：5h 满了显示周额度和重置时间" summary-multi-pool 'q["text"].split(" ｜ ")[0].startswith("Gemini 本周 剩余 99% · ") and q["text"].split(" ｜ ")[2].startswith("Claude/GPT 本周 剩余 100% · ")'
check "汇总：周额度 ≤10% 时不被 5h 盖住" summary-weekly-low 'q["text"].split(" ｜ ")[0].startswith("Gemini 本周 剩余 5% · ") and q["low"] is True'
check "汇总：每一行都带重置时间" summary-all-50 'all(seg.endswith(" 重置") for seg in q["text"].split(" ｜ ")) and len(q["text"].split(" ｜ ")) == 3'
# 合并显示用的结构化行 grid：第一行（名字为空）= Gemini 池 + 独立池，第二行「Agy C/G」= Claude/GPT 池的各个窗口（5h | 周）
check "grid：Gemini 池 + Arg 一行，Agy C/G 的 5小时 | 本周 另一行" summary-multi-pool 'q["grid"][0]["name"] == "" and q["grid"][0]["cells"][0].startswith("本周 剩余 99% · ") and q["grid"][0]["cells"][1].startswith("Arg 剩余 46% · ") and q["grid"][1]["name"] == "Agy C/G" and [c.split(" 剩余")[0] for c in q["grid"][1]["cells"]] == ["5小时", "本周"] and all(c.endswith(" 重置") for r in q["grid"] for c in r["cells"])'
check "grid：没有 Argon 时第一行只有 Gemini 池一格" summary-two-windows 'len(q["grid"]) == 2 and q["grid"][0]["cells"][0].startswith("今日 剩余 40% · ") and len(q["grid"][0]["cells"]) == 1 and len(q["grid"][1]["cells"]) == 1'
check "grid：全部用完都是 0%，C/G 的窗口短的在前" summary-all-used-up '[c.split(" 剩余 ")[1].split("%")[0] for r in q["grid"] for c in r["cells"]] == ["0"] * 4 and [c.split(" 剩余")[0] for c in q["grid"][1]["cells"]] == ["5小时", "本周"]'
check "grid：text 不变（关闭合并显示时照旧一组一行）" summary-multi-pool 'len(q["text"].split(" ｜ ")) == 3'
check "汇总是空的：不显示（程序会退回查用户状态）" summary-empty 'q == {}'
exit $fail
