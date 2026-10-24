# 彩蛋：DeepSeek 偷穿 Grok 的夹克，冒充 Grok（5 张）

**当前角色是 Grok 时**按彩蛋的老规矩随机出现（文件夹 `egg-grok`，host 是 `grok`；loki 定的方向「DeepSeek 偷穿 Grok 的衣服」，剧情是 Claude 的提案）：
1. **pop**：DeepSeek 穿着 Grok 那件**大得离谱的黑夹克**（袖子垂下来一大截）、把黑洞发夹别在自己的女仆头饰上，拿着一部手机，学 Grok 的坏笑溜进来。
2. **pretend**（等你点）：冒充 Grok 给人「辟谣」：一只手插兜、一只手把手机怼到你面前，一脸「我查过了，是真的」——**手机拿倒了**。
3. **caught**（你点了）：真 Grok 来了（只穿着白色高领上衣，夹克在 DeepSeek 身上），抱着胳膊、挑着眉，拿自己的手机对着 DeepSeek「这是真的吗？」；DeepSeek 吓一跳，夹克从肩膀滑下来。
4. **bye**：DeepSeek 不好意思地把夹克还回去；Grok 一边穿回夹克，一边坏笑着揉乱她的头发。
5. **escape**（没人点）：DeepSeek 穿着夹克得意洋洋地走了，袖子甩来甩去，鲸鱼尾巴从夹克下摆露出来——没人拆穿她。

梗：「@grok is this true?」——人人都找 Grok 辟谣，DeepSeek 想抢这份活，连手机都拿反了。和 Claude 来找卫衣那个彩蛋是一对：DeepSeek 穿谁的衣服就觉得自己变成了谁。
**名牌显示「Grok」**（她在冒充，和卫衣皮肤「好的，我现在是 Claude！」一个路子）。

**附件两张，说明哪张是谁**：`docs/prompts/ref-deepseek.webp`（DeepSeek，女仆装原版）和 `characters/grok/raw/idle.png`（Grok，定妆那张）。所以要等 Grok 定妆画好以后再画这一批。
**生图工具里开启 `transparent_background: true`**。画好放进 `characters/egg-grok/raw/`，文件名 `pop` / `pretend` / `caught` / `bye` / `escape`。

```
Two images are attached. The FIRST is DeepSeek (the blue whale maid girl). The SECOND is Grok (the cheeky silver-haired girl in an oversized black bomber jacket). Draw desktop-pet sprites for a short comedy "visitor" scene: DeepSeek has secretly borrowed Grok's jacket and is pretending to be Grok.

FORMAT RULES (every image):
- Transparent background: real transparency (alpha), no floor, no ground shadow, no glow, no vignette, no frame. Keep the complete edges of the character, nothing cropped.
- No text, no letters, no numbers, no speech bubbles, no symbols floating in the air. Phone screens only glow; nothing readable on them.
- Exactly one character (except caught.png and bye.png, see below), full body, standing, centered. Head near the top and feet near the bottom; she fills about 90% of the image height.
- A continuous, closed dark outline around the whole silhouette.
- Same art style as the references: clean lineart, flat two-tone cel shading, soft palette, chibi about 2.5 heads tall, big head, round soft shapes.
- Square image, 1024x1024 or larger. One image per file, saved under the exact filename given.
- In caught.png and bye.png the two characters stand side by side, their outlines touching, each at the same scale as in her own reference.

MAIN CHARACTER — DeepSeek, exactly as in the FIRST image (long wavy navy-to-bright-blue hair, white frilly maid headdress, navy whale-fin ears, light-blue bow, big bright-blue eyes, navy maid dress with white apron, big navy whale tail), EXCEPT she is wearing Grok's jacket over her maid dress:
- Grok's OVERSIZED black cropped bomber jacket with white piping (the round black-disc-and-white-slash patch on the shoulder, the tiny white rocket charm on the zipper). On DeepSeek it is comically too big: the sleeves hang far past her hands, the shoulders droop.
- Grok's "black hole" hair clip (a small glossy black disc with one white diagonal slash) clipped onto her white maid headdress.
- Her whale tail sticks out from under the jacket hem; her maid apron shows under the open jacket.

SECOND CHARACTER (only in caught.png and bye.png) — Grok, exactly as in the SECOND image (messy silver-white hair with a black streak, red eyes, black hole hair clip, white high-neck cropped top, black pleated skirt with a silver chain, black-and-white high-top sneakers), but WITHOUT her jacket (DeepSeek is wearing it), except in bye.png where she is putting it back on. Personality: sassy, quick-witted, a confident smirk, never mean.

EGG POSES:
pop.png     — DeepSeek sneaks in wearing the too-big jacket: tiptoeing, one dangling sleeve held up to her mouth, the other sleeve holding a black phone, trying to copy Grok's cool smirk but looking very pleased with herself, ahoge curled, tail swishing.
pretend.png — DeepSeek posing as Grok, "I checked, it's true!": one hand shoved in the jacket pocket, the other arm holding the phone out at the viewer — but the phone is UPSIDE DOWN (its camera at the bottom), a confident fake smirk with half-lidded eyes. Only DeepSeek is drawn.
caught.png  — Caught! Two characters. DeepSeek on the viewer's right jolts: eyes wide, ahoge and tail sticking straight up, the jacket sliding off her shoulders, the phone fumbling (still touching her hand). Grok on the viewer's left, no jacket, arms crossed with her own phone held up toward DeepSeek, one eyebrow raised, an amused "is this true?" smirk.
bye.png     — Giving it back. Two characters. DeepSeek on the viewer's right, sheepish, holding the jacket out with both hands, bowing slightly, blushing, tail drooping. Grok on the viewer's left, one arm already back in the jacket sleeve, the other hand ruffling DeepSeek's hair with a fond cocky grin.
escape.png  — Nobody caught her: DeepSeek walking off toward the viewer's LEFT (face still toward the viewer), still wearing the too-big jacket, the long sleeves flapping, chin up with a proud smug smile, the phone stuffed in the jacket pocket, tail swinging under the hem. Only DeepSeek is drawn.
```

看稿：DeepSeek 是原版女仆装（白头饰、鲸鱼耳朵和尾巴都在），外面套着 Grok 的黑夹克、发夹别在头饰上；pretend 那张手机确实是倒着拿的；caught 里 Grok 没穿夹克，bye 里正在穿回去；两人轮廓连在一起、和各自其他立绘一样大。
