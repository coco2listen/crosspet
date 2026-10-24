# 角色：Grok（xAI）

2026-10-24 提前准备（很多用户希望接入 Grok）。下面的外形和性格是 Claude 提的**方案，等 loki 定**；定了再画设定稿。之前 PR #25 那版「魅魔娘」Grok 没收立绘，这里是另起的设计。

## 接入什么（2026-10-24 查的）

- **Grok Build**：xAI 2026-05 发布的官方命令行编程工具（终端里的 coding agent，有计划模式、并行子任务、MCP）。
- **它有钩子，格式几乎就是 Claude Code 那套**（官方文档 https://docs.x.ai/build/features/hooks ，2026-07-02 更新）：
  - 配置是 JSON 文件：个人的放 `~/.grok/hooks/*.json`，项目的放 `<项目>/.grok/hooks/*.json`；项目钩子要先信任（`/hooks-trust`）。
  - 事件：`SessionStart` / `SessionEnd`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse` / `PostToolUseFailure`、`PermissionDenied`、`Stop` / `StopFailure`、`Notification`、`SubagentStart` / `SubagentStop`、`PreCompact` / `PostCompact`。
  - 事件 JSON 从 stdin 进来，字段是**驼峰写法**：`hookEventName`、`sessionId`、`cwd`、`toolName`、`toolInput`；环境变量里还有 `GROK_HOOK_EVENT`、`GROK_SESSION_ID`。`timeout` 单位是秒。
  - ⚠️ **它也会读 Claude Code（`.claude/settings.json`）和 Cursor（`.cursor/hooks.json`）的钩子文件**。已经接入 Claude Code 的用户一用 Grok Build，CrossPet 的 Claude 钩子很可能也会被它触发，桌宠就会以为是 Claude 在干活。接入时要先实测：是只读项目里的 `.claude/settings.json`，还是连 `~/.claude/settings.json` 也读；是的话钩子要能认出「其实是 Grok」（比如看有没有 `GROK_HOOK_EVENT` 环境变量），换成 Grok 角色、也不重复演。
  - 文档里没写事件带不带模型名；Grok Build 用的是 xAI 自家模型（现在是 grok-4.7），先按「Grok Build 一律是 Grok」处理。
- 别的宿主（Claude Code 走兼容接口、Cursor、Hermes、WorkBuddy……）里模型名带 `grok` 时也换成她，和现在按模型换角色的规则一样。
- Grok 桌面版（App）有没有对外接口还没查，先只做「切到它时换形象」。

## 设定（方案）

**性格**：嘴毒、机灵、爱抬杠的**叛逆小妹**。有问必答、反应快，答案里总夹着一句俏皮话；谁说的话都要先查证一遍，连自家老板也照怼不误；偶尔开「辣味模式」嘴上没把门，但从不刻薄伤人。
和其他角色的位置：Claude 安静爱书、GPT 冷静御姐、DeepSeek 勤快（其实有点懒）的女仆、GLM 心机涨价狐、Qwen 温柔千金——Grok 是**满嘴俏皮话的街头太空少女**，整组里唯一穿便服、最「皮」的那个。

**外形**（黑白 + 一点红，和 GLM 的黑白女仆、GPT 的白龙靠发色和衣服区分）：
- 齐肩、乱翘的**银白短发**，左边一缕**黑色挑染**；一根翘起的呆毛
- **红色眼睛**（整组里没有红眼，「辣」的意思），常带一点坏笑
- 左侧头发上别着**黑洞发夹**：黑色圆片上一道白色斜杠（xAI / Grok 标志的样子）
- **超大号黑色短款飞行夹克**，白色滚边，袖子长到盖住半个手掌；左肩一枚同样的「黑圆 + 白斜杠」臂章；拉链上挂一个小火箭挂件
- 里面白色高领短上衣，黑色百褶短裙配一条银色腰链，黑白高帮运动鞋
- **招牌道具：一部黑色手机**（给人「查证」用，屏幕只发光、不画字）
- 表达情绪：坏笑、挑眉、眨一只眼吐舌头「略」；手插夹克口袋；拿手机怼到你面前；生气时把夹克领子竖起来

## 梗（2026-10-24 查的）

| 梗 | 来源 | 用在哪 |
|---|---|---|
| **@grok is this true?** | X 上人人都 @Grok 让它给帖子辟谣、当裁判，成了全网口头禅（2025 年起） | `searching`：举着手机、眯眼查证；闲着的专属动作 `factcheck`：手机怼到你面前「我查过了」 |
| **拆自家老板的台** | Grok 多次当众反驳马斯克本人，「Grok 背叛马斯克」上过热搜（2026-08） | 闲着的专属动作 `sass`：抱着胳膊斜眼坏笑；台词「谁说的我都得查一下，老板也不例外」（**不画也不点名真人**） |
| **辣味模式（Spicy / Unhinged）** | Grok 的「嘴上没把门」模式 | `proud`（大活完成）：咬着一根小红辣椒、眨眼比 V「这把够辣」（只取「辣」的字面意思，**不碰成人内容**） |
| **银河系漫游指南** | Grok 的名字和说话风格来自这本书：答案是 42、「Don't Panic」、出门带毛巾 | `oops`：把一条毛巾顶在头上「Don't panic」；`thinking` 的台词「答案是 42……开玩笑的」（数字只写在台词里，不画） |
| **太空 / 火箭** | Grok 出自 xAI，和 SpaceX 一家（官方文档站标题现在就是「SpaceXSI」）；名字也来自太空科幻 | 拉链上的小火箭；`running`：骑着一枚小火箭冲出去 |
| **DeepSeek 偷穿 Grok 的衣服** | 彩蛋（loki 定） | `egg-grok`，见 [06](06-彩蛋-DeepSeek偷穿夹克.md) |

**不碰**：政治人物和事件、Grok 闹过的仇恨言论风波、成人向的「伴侣」角色。马斯克本人不出现在任何图和台词里，只用「老板」代指。

## 全套（新画 55 张 + 设定稿 2 张，彩蛋另 5 张）

| # | 批次 | 张数 |
|---|---|---|
| 0 | [00-定妆.md](00-定妆.md)：设定稿 `idle` + 眨眼 `idle-blink`（没有参考图，先画这张定下长相） | 2 |
| 1 | [01-基础.md](01-基础.md) | 11 |
| 2 | [02-进阶.md](02-进阶.md)（含辣椒 `proud`） | 13 |
| 3 | [03-专属与红温.md](03-专属与红温.md)（`factcheck`、`sass` + 红温 7 张） | 9 |
| 4 | [04-多会话与贴边.md](04-多会话与贴边.md) | 4 + 2 + 2 |
| 5 | [05-时段与节日.md](05-时段与节日.md) | 6 + 8 |
| 6 | [06-彩蛋-DeepSeek偷穿夹克.md](06-彩蛋-DeepSeek偷穿夹克.md) | 5 |
| + | 展示图 / 探头头像：见 [展示立绘](../展示立绘/README.md)，表里加一行 Grok | 2 |

- 先画 [00](00-定妆.md)，满意了存成 `characters/grok/raw/idle.png`。**之后每批都只附这一张**，夹克、发夹、手机才不会每张不一样。
- 每批都开 `transparent_background: true`，拼法：00 里的「格式规则」→「角色锁定」→ 这一批的 POSES。
- 每批画完缩到约 200px 看：银发黑挑染、黑洞发夹、黑夹克和肩章、红眼都在；和 GLM、GPT 并排时一眼分得出。
