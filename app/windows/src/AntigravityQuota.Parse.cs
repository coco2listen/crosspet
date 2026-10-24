using System;
using System.Collections.Generic;
using System.Linq;

namespace CrossPet
{
    // 额度回复的排版（不依赖 Windows，tests/windows/LogicTests 在 macOS 上测）。取额度的部分在 AntigravityQuota.cs
    static partial class AntigravityQuota
    {
        /// <summary>
        /// 额度按「额度池」共享：Gemini 模型一个池，Claude 和 GPT 模型一个池（Antigravity 的「View Usage」也是这两组）。
        /// 固定显示这两行，Gemini 在前；重置时间标在第一行和快用完的那行上。和 macOS 版 antigravityQuota 一样。
        /// </summary>
        /// <summary>额度汇总或用户状态，哪种都认（汇总优先）</summary>
        public static Dictionary<string, object> Parse(object obj) => ParseSummary(obj) ?? ParseStatus(obj);

        /// <summary>额度汇总（RetrieveUserQuotaSummary）：Antigravity 自己分好组（「Gemini Models」「Claude and GPT models」），
        /// 每组一个或几个窗口（5h / 本周 / 今日……）。text 给关闭「合并显示」时用（每组一行）；grid 给合并显示用：
        /// 第一行（name 为空 = 用角色自己的名字）是 Gemini 池 + 独立池（Arg）各一格，第二行「Agy C/G」是 Claude/GPT 池的各个窗口。和 macOS 版 antigravitySummary 一致</summary>
        public static Dictionary<string, object> ParseSummary(object obj)
        {
            if (!(obj is Dictionary<string, object> root) || !(root.TryGetValue("response", out var r0) && r0 is Dictionary<string, object> resp)) return null;
            if (!(resp.TryGetValue("groups", out var gs) && gs is object[] groups)) return null;
            string Title(Dictionary<string, object> g) => g.TryGetValue("displayName", out var t) ? t as string ?? "" : "";
            var rows = new List<(string name, double left, DateTime? reset)>();
            (string label, double left, DateTime? reset)? gemini = null;
            var others = new List<(string label, double left, DateTime? reset)>();
            var gpt = new List<(string label, double left, DateTime? reset)>();
            string Piece((string label, double left, DateTime? reset) r)
            {
                var piece = $"{r.label} 剩余 {(int)Math.Round(r.left * 100)}%";
                if (r.reset is DateTime t)   // 每行都标重置时间（和 macOS 版一致）
                    piece += $" · {((t - DateTime.Now).TotalHours < 24 ? t.ToString("HH:mm") : $"{t.Month}/{t.Day}")} 重置";
                return piece;
            }
            foreach (var g in groups.OfType<Dictionary<string, object>>().Select((g, i) => (g, i)).OrderBy(x => Title(x.g).Contains("Gemini") ? 0 : 1).ThenBy(x => x.i).Select(x => x.g))
            {
                var title = Title(g);
                var isGemini = title.ToLowerInvariant() == "gemini models";
                var isGpt = !isGemini && (title.Contains("Claude") || title.Contains("GPT"));
                var name = isGemini ? "Gemini" : isGpt ? "Claude/GPT" : title;
                var buckets = (g.TryGetValue("buckets", out var bs) && bs is object[] arr ? arr : new object[0]).OfType<Dictionary<string, object>>().ToList();
                // 每组在 text 里只留一行（和 macOS 版一致）：有 5h 窗口、且 5h 没满 → 显示 5h；5h 满了 → 显示别的窗口里最紧的（一般是周额度）；
                // 例外：最紧的窗口 ≤10% 时不管 5h 怎样都显示它。一样紧的取重置得更晚的，不看接口给的顺序
                var cands = new List<(string win, string window, double left, DateTime? reset)>();
                foreach (var b in buckets)
                {
                    // 比例为 0 时会被省略（protobuf 转 JSON 不写默认值）：窗口在、比例不在 = 用完了
                    var left = b.TryGetValue("remainingFraction", out var f) ? Convert.ToDouble(f) : 0;
                    var win = b.TryGetValue("window", out var w) ? w as string ?? "" : "";
                    var window = win == "weekly" ? "本周" : win == "daily" ? "今日" : win == "5h" ? "5小时" : (b.TryGetValue("displayName", out var dn) && !string.IsNullOrEmpty(dn as string) ? (string)dn : win);
                    var resetText = b.TryGetValue("resetTime", out var rt) ? rt as string ?? "" : "";
                    DateTime? reset = DateTime.TryParse(resetText, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d) ? d.ToLocalTime() : (DateTime?)null;
                    cands.Add((win, window, left, reset));
                }
                if (cands.Count == 0) continue;
                var tightest = cands[0];
                foreach (var c in cands.Skip(1))
                    if (c.left < tightest.left || (c.left == tightest.left && (c.reset ?? DateTime.MinValue) > (tightest.reset ?? DateTime.MinValue))) tightest = c;
                var five = cands.FirstOrDefault(c => c.win == "5h");
                var pick = tightest.left > 0.1 && five.win == "5h" && five.left < 1 ? five : tightest;
                rows.Add((cands.Count > 1 ? $"{name} {pick.window}" : name, pick.left, pick.reset));
                // grid：Gemini 池一格（挑出来的那个窗口）；独立池一格（名字缩短：Argon → Arg）；Claude/GPT 池每个窗口一格，短窗口在前
                if (isGemini) gemini = (pick.window, pick.left, pick.reset);
                else if (isGpt)
                {
                    int Order(string win) => win == "5h" ? 0 : win == "daily" ? 1 : win == "weekly" ? 2 : 3;
                    gpt = cands.OrderBy(c => Order(c.win)).Select(c => (c.window, c.left, c.reset)).ToList();
                }
                else
                {
                    var shortName = title.StartsWith("Gemini ") ? title.Substring("Gemini ".Length) : title;
                    if (shortName.ToLowerInvariant().EndsWith("argon")) shortName = "Arg";
                    others.Add((cands.Count > 1 ? $"{shortName} {pick.window}" : shortName, pick.left, pick.reset));
                }
            }
            if (rows.Count == 0) return null;
            var grid = new List<object>();
            var first = new List<(string label, double left, DateTime? reset)>();
            if (gemini != null) first.Add(gemini.Value);
            first.AddRange(others);
            if (first.Count > 0) grid.Add(new Dictionary<string, object> { ["name"] = "", ["cells"] = first.Select(Piece).ToList() });
            if (gpt.Count > 0) grid.Add(new Dictionary<string, object> { ["name"] = "Agy C/G", ["cells"] = gpt.Select(Piece).ToList() });
            return new Dictionary<string, object>
            {
                ["text"] = string.Join(" ｜ ", rows.Select(r => Piece((r.name, r.left, r.reset)))),
                ["low"] = rows.Min(r => r.left) <= 0.1,
                ["grid"] = grid,
            };
        }

        /// <summary>用户状态（GetUserStatus，旧版 Antigravity 的退路；里面的额度是模型列表顺带的缓存，会慢几分钟）</summary>
        public static Dictionary<string, object> ParseStatus(object obj)
        {
            if (!(obj is Dictionary<string, object> root) || !(root.TryGetValue("userStatus", out var st) && st is Dictionary<string, object> status)) return null;
            if (!(status.TryGetValue("cascadeModelConfigData", out var cfg) && cfg is Dictionary<string, object> config)) return null;
            if (!(config.TryGetValue("clientModelConfigs", out var ms) && ms is object[] models)) return null;
            // 固定两行，和 Antigravity 自己「View Usage」的分组一样：Gemini 模型一行，Claude 和 GPT 模型一行。
            // 数字相同也不合并（以前按「剩余 + 重置时间」合并，行数会变来变去，和 Antigravity 对不上）。和 macOS 版 antigravityQuota 一致
            var groups = new List<(string name, double left, DateTime? reset)>();
            foreach (var m in models.OfType<Dictionary<string, object>>())
            {
                if (!(m.TryGetValue("quotaInfo", out var qi) && qi is Dictionary<string, object> info)) continue;
                // 不可用的模型不算：比如只给 Ultra 套餐的「Gemini 4 Argon」，别的账号里标着 disabled、额度信息是空的，
                // 以前被当成「剩 0%」排在第一行（2026-10-14 两位用户反馈）
                if ((m.TryGetValue("disabled", out var dis) && dis is bool off && off) || (!info.ContainsKey("remainingFraction") && !info.ContainsKey("resetTime"))) continue;
                var left = info.TryGetValue("remainingFraction", out var f) ? Convert.ToDouble(f) : 0;   // 用完时这个字段会被省略（但还有重置时间）
                var resetText = info.TryGetValue("resetTime", out var r) ? r as string ?? "" : "";
                DateTime? reset = DateTime.TryParse(resetText, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d) ? d.ToLocalTime() : (DateTime?)null;
                var name = ((m.TryGetValue("label", out var l) ? l as string : null) ?? "").StartsWith("Gemini") ? "Gemini" : "Claude/GPT";
                var i = groups.FindIndex(g => g.name == name);
                if (i < 0) groups.Add((name, left, reset));
                else if (left < groups[i].left) groups[i] = (name, left, reset ?? groups[i].reset);
            }
            if (groups.Count == 0) return null;
            groups = groups.OrderBy(g => g.name == "Gemini" ? 0 : 1).ToList();
            var parts = groups.Select((g, i) =>
            {
                var piece = $"{g.name} 剩余 {(int)Math.Round(g.left * 100)}%";
                // 重置时间标在第一行（Gemini）上；别的那行快用完了也标
                if ((i == 0 || g.left <= 0.1) && g.reset is DateTime t)
                    piece += $" · {((t - DateTime.Now).TotalHours < 24 ? t.ToString("HH:mm") : $"{t.Month}/{t.Day}")} 重置";
                return piece;
            });
            return new Dictionary<string, object> { ["text"] = string.Join(" ｜ ", parts), ["low"] = groups.Min(g => g.left) <= 0.1 };
        }
    }
}
