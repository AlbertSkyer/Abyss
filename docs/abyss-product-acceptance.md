# Abyss 产品目标与验收

## 交付约束

> 以下逐任务审批约束记录早期已交付行为。新的目标合同见 [产品目标](abyss-product-goals.md)：自动模式默认开启且可关闭，关闭时手动审批。文档目标不代表当前发行包已实现自动调度，阶段状态见文末。

- Abyss 与原版 BaoCode 可同时安装、启动，数据、会话、配置、任务和凭据独立；不读取或复制原版凭据。
- 用户只与主代理对话；所有代理使用外部 Claude Code CLI，不以内置内核替代验收。
- 主代理提出子任务后，必须先展示任务说明和模型下拉选择；确认后才执行，取消不启动。并发审批不能覆盖彼此。
- 子任务详情只读，无 composer；不同提供商的可用模型可分配给并行子任务，实际路由必须与选择一致。
- 关闭主会话窗口不等于退出整个应用；前者不终止后台子任务。整个应用退出或崩溃后的执行不承诺继续，但恢复状态不能把中断误报为失败或完成。
- 子任务结果返回主代理，由主代理汇总；完整子任务历史供只读浏览，不自动灌入主对话。
- 整体侧栏及每个主会话的子任务列表独立折叠，保留偏好和运行/未读提示。

## 验收口径

分别记录三层证据，不能混称端到端通过：

1. **单元/组件测试**：隔离路径、状态机、UI 只读边界、模型选择接线。
2. **真实 CLI 协议测试**：实际外部 CLI 进程和本地受控响应，验证审批/取消/模型输入及会话文件；不使用真实上游凭据或付费请求。假 transport 不能替代此层。
3. **真实产品流程**：运行交付包，用户在审批界面确认/取消，真实上游执行小规模任务并回报主代理。未配置 Abyss 自己的上游时不得借用 BaoCode 凭据。

核心场景：提出两个无害只读子任务，二者都在审批前不执行；取消一个、为另一个选择模型并确认；另测两个获批任务并发。检查主模型未变、实际请求路由、侧栏条目、只读详情、主窗口关闭后执行、重新打开后的结果与状态。

## 2026-11-15 已有证据

- 托盘修复检查点 `fdee1630` 已推送至 `origin/edition/abyss`；未向 upstream 推送。
- 交付包 `dist/Abyss-portable-20261115-tray-verified` 已与原版共存启动，窗口身份及托盘交互通过。
- `test/platform/app_edition_test.dart` 和 `test/tool/build_windows_test.dart` 共 4 项通过。
- `test/platform/app_edition_abyss_test.dart` 原有身份/目录测试及新增 Windows secret-store 目录、onboarding 写入隔离测试共 5 项通过。测试只使用临时目录与虚构标记，不读取真实秘密，不代表真实模型会话已经写入成功。

## 当前开发轮次的定向验证

- Abyss CLI-only 内核选择与设置界面：BaoCode/Abyss 两种配置各 2 项通过。Abyss 即使没有安装 CLI 或保存旧 builtin 设置，也选择 CLI；不能据此声称远程路径或真实模型执行已经验收。
- 整体侧栏显隐/宽度持久化、延迟偏好不覆盖用户操作、窄窗口/侧板临时布局不写偏好，以及原有切换/拖拽：5 项通过。
- 恢复根任务的最终报告映射：completed/failed/interrupted 共 3 项通过；另有 host 审批能力不冒充私有任务控制能力测试。使用受控协议帧，不是 CLI 自身恢复实证。
- 上述修改文件定向静态分析通过。
- 中英文 ARB 键一致和中文翻译检查 2 项通过。尝试运行整个 `test/l10n_test.dart` 时另有一项未通过：命令目录仍写 `Star BaoCode on GitHub`，英文翻译已是 `Star Abyss on GitHub`；本轮新增内核文案未引入该不一致，尚未修复。

- 左侧主会话下新增真实 AgentItem 子任务分组，与可写 /btw asides 分开；父会话独立折叠持久化、运行/未读提示、点击只读详情定向测试通过。不为绘制列表启动未打开历史会话的 kernel；未加载的历史任务列表仍不展示。
- Abyss 的 AgentApprovalRequest 使用独立模态，复用原有任务说明与模型选择；确认、取消、外部回答、请求替换测试通过。BaoCode 保持内联审批。
- 新增 `tool/verify_cli_agent_hook.dart`，真实 CLI 2.1.311 + loopback 假 endpoint，无真实凭据/付费请求。已实测 PreToolUse 在执行前等待、deny 后 spawned=0；任意全模型 ID 不可直接写 Agent.model。静态命名 agent definition 支持全 ID，但不能据此覆盖内置 Explore 并声称语义不变。初始化缺少 `hooks_applied:true` 时 Abyss 拒绝开始会话，避免旧 CLI 静默跳过审批。
- 已实测合法 alias + ANTHROPIC_DEFAULT_HAIKU_MODEL 可让保留原 subagent_type 的子代理向本地 endpoint 请求 `@other/provider-model`。当前实现将本地 provider 会话模型池的前 **3** 个可用模型映射到 sonnet/opus/haiku，审批显示模型 ID 后转换 alias；主模型不变。超过 3 个模型、远程会话和无 provider 的会话尚不支持任意跨提供商选择，不能称无限模型池。进程强制 subagent 设置不被覆盖。
- 主窗口隐藏/托盘保活与显式 Quit 的组件测试通过，但真实耗时子任务在交付包中的关闭/重开流程仍待验收。
- 真实 CLI `--persist` 本地受控请求产生 JSONL，只写入新建的 build/cli-hook-probes 临时 config，不使用用户原版配置。此证据不涉及真实付费模型。
- 第一轮 agent-workbench Release 已成功构建并通过独立身份检查；用新建测试数据目录实际启动，查看非空界面、打开设置并执行 Ctrl+B，隐藏状态已写入测试 state.json。测试实例已单独退出，原版 BaoCode 和用户旧 Abyss 保持响应。
- 最后修订已重新构建到 `dist/Abyss-portable-20261115-agent-workbench-final`，app.so SHA-256 为 `634E005ED5880134E79948AED52607590988332CA53A1A51AE6444D9A49AB4E9`；隔离启动及非空界面截图通过。复用托盘驱动在同机多实例时未捕获菜单，返回失败，不能标记本轮托盘交互通过。最终实例的 Ctrl+B 因前台窗口检查失败未发送按键，不能把第一轮交互冒充最终包交互；已单独退出测试实例。
- 真实 CLI loopback 双任务实验：两次审批都在确认前等待；分别允许后实际请求 `@other/provider-model` 与 `@other/second-model`；另一次取消第一任务，仅第二模型收到子代理请求。两次脚本退出 0。此实验是 CLI 协议证据，不是 GUI+真实 provider 的端到端验收。

## 2026-11-15 真实交付包 + 上游验收

用户随后明确撤销了此前人民币 5 元的预算门禁，要求直接验证功能；本轮只执行小规模、无工具、无文件修改的心算子任务。用户修正 Abyss 自身的上游配置后继续验收，不读取或复制 BaoCode 凭据。此前的未登录错误不作为修正配置后的验收结论。

运行包为 `dist/Abyss-portable-20261115-agent-workbench-final`，外部 CLI 2.1.311。Abyss 窗口属性为 `Abyss.OpenRequests=1`、`BaoCode.OpenRequests=0`，与原版 BaoCode 同时响应。以下是该运行包的证据，不代表后续修复包已通过同样的 GUI 验收：

- **审批与取消：** A/B 两任务逐个展示任务说明和模型下拉框，即使完全访问模式也需审批。取消 A 后没有启动子代理，B 确认后返回 `667`，主代理正确汇总。实际发现缺陷：A 在侧栏被显示为“失败”，而不是取消；该状态错误需修复，不能把取消流程整体标为无缺陷。
- **跨提供商路由：** 临时通过设置加入 DeepSeek、Kimi 两个池模型；C 选择 DeepSeek 返回 `1147`，D 选择 Kimi 返回 `1763`。CLI 的 resolvedModel 与子日志实际响应模型分别吻合，主会话保持 `gpt-6.1-sol`。C/D 是先后提出，不计为并发通过。
- **后台保活：** D 获批后关闭主窗口，Abyss 窗口隐藏、MainWindowHandle 为 0，但应用和外部 CLI 进程仍运行；重新打开同一个包后结果返回主代理。没有执行整个应用的 Quit，不声称退出或崩溃后仍可继续运行。
- **只读详情：** 点击侧栏 B 子任务，实际界面显示子任务结果、没有 composer。截图 `build/abyss-live-child-readonly.png`。
- **并发排查：** E/F 也得到正确结果，但 E 于 07:35:13.960Z 完成、F 于 07:38:53.014Z 才启动，没有重叠；不计入并发通过。
- **真实跨提供商并发通过：** 最后一组 G/H 在同一条 assistant 消息提出，消息时间为 07:40:36.950Z / .955Z；两次审批分别确认，界面同时显示两个运行中任务。G 实际为 Kimi，运行区间 07:41:20.463Z–07:41:22.844Z，返回 `G=4891`；H 实际为 DeepSeek，区间 07:41:20.910Z–07:41:22.149Z，返回 `H=5609`。运行区间重叠约 **1.239 秒**。主代理收到两份真实报告后汇总，未用预期答案冒充报告。截图 `build/abyss-live-overlap-started.png` 与 `build/abyss-live-overlap-complete.png`；时间均为 UTC。
- **侧栏交互：** 折叠当前父会话的子任务组，另一 Test 会话的子任务组保持展开，折叠组仍显示 6 个未读提示；Ctrl+B 实际隐藏、再次展开整体会话栏。截图 `build/abyss-live-folded-parent.png`、`build/abyss-live-sidebar-hidden.png`。偏好跨整个应用重启仍仅有组件测试证据。
- **验收清理：** 两个临时模型池条目已通过设置移除，恢复原空池；未移除 provider 或凭据，验收会话和结果保留。截图 `build/abyss-live-pool-restored.png`。

真实日志仅检查本次验收会话 `c1deb9b9-5b31-4d67-937f-b739308abd13` 的 Agent 调用、模型和子日志时间，不收集完整配置或密钥。小任务证明可重叠运行及正确路由，**没有测试最大吞吐或持续打满多个 provider 的额度**。

### 本轮缺陷与未验收边界

- 取消的 Agent 错标“失败”：已修复当前 translator 生命周期内的 host hook 拒绝映射，侧栏显示“已取消”，迟到的 permission_denied/error 不会覆盖；真实执行错误仍为失败。取消决议目前仅存内存，整个应用重启后缺少持久化的 host 决议仍可能恢复为失败，**这一恢复缺陷尚未解决**，旧运行包和既有历史记录也不能自动当作已修复。
- 模型设置说明仍称“CLI 不使用模型池”：改为 Abyss 专属中英文说明，明确本地 provider 会话、前 3 个可用模型、逐任务审批与强制模型优先；BaoCode 原文案不变。
- 尚未实证：整个应用退出/重启后的完整任务恢复索引、远程 CLI 跨 provider、超过 3 个模型的池、长期高吞吐；不能据本轮小任务称整个产品全部验收完成。

### 本轮修复的定向验证

- Abyss hook 审批组 7 项与新增侧栏取消/中断/失败区分 1 项：共 8 项通过。
- 取消状态回归、模型池设置组、中英文 ARB 一致性：合并筛选共 8 项通过；BaoCode 原模型池说明单项另行通过。
- 审批测试文件与历史报告测试文件最终联合运行：19 项通过。
- 修改的 kernel、translator、模型设置、侧栏及其测试文件静态分析：无问题。
- 首次文案测试碰到并行编辑中的 Dart 编译错误，修正后已重跑通过；一次使用 plain-name 传正则没有匹配测试，改用 name 后实际执行通过。
- 子代理额外运行整个 `test/kernel_test.dart`：135 通过、8 跳过、9 失败（Windows 路径断言及模型选择相关）。没有把该文件称为通过，也没有扩展修复范围；普通停止 turn 的定向用例单独通过。未运行全产品测试套件。

### 修复包交付

- 新包：`dist/Abyss-portable-20261115-agent-live-fixes/Abyss.exe`，未覆盖正在运行的 agent-workbench-final，也未删除旧包。
- Release 实际构建成功，Flutter 保留的 build-dir 指向 `build/abyss-independent-final-20261115`；首次脚本检查了错误的 `build/abyss` 旧产物而失败。随后对日志中实际新产物执行 skip-build 打包，Abyss.exe 与 app.so 独立身份检查通过，没有用旧产物冒充新构建。
- SHA-256：Abyss.exe `73544A4215ADA774731E492A2D725ED7BE926A2B02042F93CBF24E32002B8521`；data/app.so `0754908543B5A381B2795D0EDD30B535C92DE45B31FC2234FC93CF7EAE5A75C6`。
- 用新建空数据目录隔离启动修复包，实际打开模型设置并查看截图，确认中文模型池说明已更新；窗口响应及 Abyss-only 属性正确。截图 `build/agent-live-fixes-smoke/window.png`、`build/agent-live-fixes-smoke/models.png`。此空测试实例已单独退出，用户 Abyss 与原版 BaoCode 仍响应。
- 修复包没有复制真实凭据或重复运行付费任务；取消显示修复是定向 kernel/widget 测试证据，不宣称已在修复包内重新完成真实上游端到端验收。

## 编辑器工作区第一批（2026-11-15）

### 已实现的增量

- Abyss 顶部“窗口”菜单，复用真实会话导航、搜索、现有 IDE/终端/侧栏及设置入口；列出已打开标签而非全部历史。BaoCode 的菜单栏不增加该入口。不是所有功能已变成通用可停靠面板。
- 会话右键“在新标签页打开”“在右侧打开”；单击预览、双击固定、输入即时固定，固定标签不因旧覆盖栈容量而被静默淘汰。
- 真实多会话分屏、同会话去重、标签排序和跨标签组拖动；右侧打开移动已有标签，不复制 session/CLI。首批仍为最多四个分屏区域，不是任意停靠树。
- 草稿按原会话保存，关闭最后标签允许空工作区；布局、活动会话、固定/预览状态兼容原存储结构并恢复。阅读位置暂沿用已有 feed 内存锚点，**跨整个应用重启的阅读锚点持久化未实现**。
- Abyss 视图 detach 不释放 session kernel，已打开会话由业务 dispose 管理；不为了隐藏列表或恢复布局预启动全部历史。此首批采用会话生命周期保活，不是完整资源预算/闲置回收策略。
- “显示左侧子代理列表”独立设置 `abyss.sidebar.showAgentTasks` 默认 false，可在设置和窗口菜单切换；仅隐藏行，不清除历史、未读或折叠状态，不影响审批。BaoCode 保留原显示行为。

### 定向测试与分析

- 网格测试文件 17 项通过，包含新增固定标签不淘汰、移除分屏不丢其他标签、活动/覆盖标签移动排序。
- 最终 Abyss 定向组合 13 项通过：标签/分屏/拖动、预览草稿保护、布局空态恢复、菜单导航、显示设置、生命周期及 ARB 一致性；非整套测试通过声明。
- BaoCode 生命周期及原窗格恢复定向组合 5 项通过；另验证默认显示规则与生命周期 2 项通过。
- 分屏点击焦点、已有会话定位、鼠标前后导航与新增标签场景组合 5 项通过。没有据此声称付费模型发送/停止/审批在新包内全部重验。
- 修改文件定向静态分析无问题。实现中遇到的 Dart 类型/状态错误已由主代理接手修复；设置测试修正真实文件 IO 的 runAsync 和错误重建 Workspace 夹具后，仍通过真实 UI 点击验证，未绕过 onChanged 冒充通过。

### 真实外部 CLI 续接门禁

扩展既有 `tool/verify_cli_agent_hook.dart --resume-agent`，保留创建场景；新增纯本地 fixture `tool/cli_agent_resume_probe.dart`。所有请求只到 loopback endpoint，使用全新配置目录与假 token，无真实凭据、无付费上游请求。

- 本机 CLI 2.1.311：general-purpose 创建后 `SendMessage` 的 PreToolUse 可拦截；未批准前 300ms 内无新增 child 请求。
- 允许后实际 `task_started.task_id` 与首次 agentId 相同，续接子请求历史包含首次随机标记，实际请求模型仍为 `@other/provider-model`，主请求模型不变。
- `--deny-send`：拒绝后额外观察 500ms，新增 child 请求为 0，脚本退出 0。
- `--restart-resume`：退出主 CLI 后以同主 session resume，再次 SendMessage，实际 task_id、历史标记和 child 模型保持；脚本退出 0。
- 最终使用 Abyss 自己的 CLI 可执行文件进行严格复核。日志 `build/cli-resume-verified-restart.log`、`build/cli-resume-verified-deny.log`；JSONL 均在本轮新建 `build/cli-hook-probes/resume-agent-*` 中。
- 初版探针错误等待首条 user 消息之前的 system/init，并有异步背景任务及响应去重假设问题，已修复；这些失败不被归因为 CLI 不支持。CLI 实际可能对同一逻辑响应发出多次请求，因此比较增量而不硬编码请求数。
- 这证明协议可用于后续常驻成员，不代表产品已接入成员账本、生产 SendMessage 授权、自动派工/选模或持久化停止决议。用户主动取消后的禁止续接仍待专项验证。

### 真实 GUI 验收

- 第一轮包 `dist/Abyss-portable-20261115-editor-tabs` 使用全新测试数据目录、两份人工构造本地 JSONL 会话，不复制任何用户历史或凭据，也没有发送模型任务。
- 实际点击 Alpha，右键 Beta → 新标签，确认同时保留两个标签；再右键 → 右侧打开，实际看到两个不同会话和独立输入框。
- 两侧分别输入未发送草稿 `ALPHA unsent draft` / `BETA unsent draft`，重启自建测试实例后双分屏、活动会话和两份草稿均恢复，截图已查看。
- 实际展开“窗口”菜单，看到真实导航与显示开关。窗口属性 Abyss.OpenRequests=1、BaoCode.OpenRequests=0，界面响应。
- 证据位于 `build/editor-tabs-gui-check/{two-tabs,two-panes,window-menu,drafts,restored}.png`。新建假会话初次因 JSON 空格格式未被现有 catalog 快速扫描器识别，压缩为 CLI 常用格式后正常加载；这是验收夹具调整，不改生产历史解析器。
- 用户自己的 Abyss 和原版 BaoCode 未关闭；只重启自建隔离实例。此证据不覆盖新包内真实上游发送/停止，也不覆盖浮动多屏。

### 最终包与复核

- 最终入口 `dist/Abyss-portable-20261115-editor-tabs-final/Abyss.exe`，增量 Release 成功，独立身份检查通过；未覆盖早期包。
- Abyss.exe SHA-256 `73544A4215ADA774731E492A2D725ED7BE926A2B02042F93CBF24E32002B8521`；data/app.so SHA-256 `093DD21B1DD9DCFF29FAC0F0F6EF6F3730893EAD69FA4BC321A6E8ECA06252F9`。
- 最终包使用同一隔离假会话数据启动，实际查看双会话、草稿恢复及窗口菜单，截图 `build/editor-tabs-gui-check/final-restored.png`、`final-window-menu.png`。此次没有重跑真实 provider 任务。
- 已单独退出自建最终测试实例，用户原有 Abyss 与原版 BaoCode 均仍响应；没有删除测试产物或旧包。

### 当前未完成目标

此处为第一批结束时的状态：常驻成员账本及任务证据、默认开启的自动派工选模开关、续接生产授权与并发队列、取消/停止跨重启持久化、通用停靠/面板注册、浮动多屏、跨重启阅读锚点、范围冲突及完整执行记录均未完成。后续增量见下节，不把第一批 UI 或协议探针说成整个方向完成。

## 第二批底座：宿主任务账本（2026-11-15）

### 已实现范围

- 新增 Abyss 自有 `state/agent-task-ledger.json`，不改写 CLI transcript；主会话、成员、任务、工具调用、CLI agent 与 run ID 分字段保存。同一成员可关联多项运行任务。
- 默认只接本地 Abyss Claude CLI；BaoCode 与远程路径不启用该账本。实例按文件路径共享内存与串行写队列，使用现有原子写入工具；坏文件保留并显示加载错误，未知字段兼容保留。
- Agent 创建被宿主拒绝、待审批过程结束，以及明确停止任务时记录取消/停止决议；CLI 后续失败或完成不能覆盖决议。停止与未启动取消用独立 flag 区分，当前 UI 均显示“已取消”。
- 历史回放及读取更早历史时补用宿主决议，不从错误文案猜取消。此前已取消但没有宿主账本的旧历史不会被追溯性猜改。
- 主 CLI 退出或恢复时，账本遗留 running 保守标为 interrupted，不自动重启任务。关闭仅展示面板仍不触发业务退出。
- 正常业务退出等待 kernel stopped 时包含账本 flush；写入失败可被 flush 观察，后续写入仍可恢复。
- CLI task_started/task_notification/task_updated 按实际运行关联记录，不从复用成员卡片的旧完成状态推断新任务已完成。恢复时重建成员与工具调用关联。

### 定向验证

- 账本 9 项测试、内核接线 3 项测试：共 12 项通过。存储重载测试实际从磁盘复制重开，不以同路径内存单例冒充磁盘恢复。
- 与审批及历史报告测试联合运行 31 项通过；最后成员关联小修后账本及接线 12 项重跑通过。修改文件静态分析无问题。
- 覆盖取消重建后迟到 error、真实失败不误判取消、运行任务停止后 failed 回执、同成员两次运行互不提前完成、退出后 interrupted、不同主会话隔离、错误关联保护、坏文件保留、写入失败与恢复、未知字段保留。
- 测试使用临时目录及假 CLI，不读取真实凭据、不调用付费模型，也不代表真实交付包中的取消重启流程已验收。

### 交付包与真实验收

- 新包 `dist/Abyss-portable-20261115-agent-ledger/Abyss.exe`，Release 构建与独立身份检查通过；app.so SHA-256 `AA4C3F49ABF4A2E10125D0E46E6636F9B7EF20FF291E55C08ABEFD21D60785F0`。没有覆盖运行中的旧包。
- 隔离人工历史+账本 GUI 验证：正常显示取消卡片，重启后侧栏仍为“已取消”；截图 `build/agent-ledger-gui-check/restart.png`。夹具最初缺 parentUuid 分支链，修正后正常；未因此修改生产解析器。
- 用户已授权自行控制 Abyss 进程。检查无运行任务后，通过真实托盘退出正常切换到新包，原有双会话布局恢复，原版 BaoCode 保持响应。
- 在用户 Abyss 的 Test 会话提出一次小规模无工具心算子任务 `Ledger cancellation check`，真实审批点击取消；主代理确认未启动且不重试/替代。宿主账本实际保存 hostCancelled=true。
- 随后正常退出并重开同一包，临时开启列表查看，任务仍明确显示“已取消”。查看证据 `build/abyss-ledger-live-{approval,before-restart,after-restart,restored-status}.png`；验收后已恢复左侧列表隐藏偏好，并保持新包运行。
- 本轮只核对当前验收任务的账本 session/tool ID 和取消标志，未收集凭据。真实主模型请求已发生，子任务未获批准所以没有子模型执行；没有验证真实运行中停止、常驻续接调度或故障切换。
- BaoCode 原审批/历史恢复定向 5 项另行通过。未运行全套测试。

### 边界

以上为账本增量结束时的边界。没有历史宿主决议时不会猜测取消；远程会话与旧包不自动获得这些语义。自动派工接线与后续状态见下节。

## 自动派工与真实成员续接增量（2026-11-15）

### 已接通

- 设置 `abyss.agents.autoDispatch`，Abyss 默认开启；false 关闭，删除键恢复默认。自动派工不改变普通工具权限；设置重启保留，不隐式批准已经弹出的旧请求。
- 主代理每次用户回合收到当前会话可用池模型与 CLI alias 对照、既有成员 ID/绑定模型等摘要，自行选择模型；宿主仅校验并改写 alias，不用轮询或关键词规则冒充任务适配。
- 自动新建必须明确选择池内且本次 CLI 已映射的可用模型，不指定、池外、禁用/缺失、无法使用的强制模型或状态不可用均拒绝。仍限本地 provider 会话前三映射，非无限模型池；池为空时不越权使用其他模型。
- PreToolUse 覆盖 `Agent|Task|SendMessage`。已知同主会话成员可续接、保持绑定模型；未知、已记录停止/取消、仍运行的成员不能自动继续。取消的续接按独立工具调用关联至原成员，供后续拒绝依据。
- 关闭自动模式后新建及续接都确认；续接仅显示绑定模型，不向 SendMessage 塞入 model 参数。新文案明确“成员绑定”而非环境变量强制。
- 自动运行最多 3 项，包含启动前预留槽，防止同批请求越过限制。**满额目前明确拒绝要求等待，不是完整持久化队列，也尚不可配置上限。** 手动模式仍使用原执行规则。
- 自动派工在主会话显示成员/模型动态；会话项目副标题附模式图标与悬浮信息。尚无完整常驻团队管理面板和独立角色配置。

### 定向验证

- 账本/审批/自动选模/设置相关筛选组合 25 项通过；后续成员绑定、拒绝续接后禁止自动恢复与 ARB 组合 18 项通过。修改文件定向静态分析无问题。
- 自动选择池项无需 InteractionRequested；未选择/池外被拒绝；3 个预留槽后第 4 项拒绝；手动待审批请求切回自动仍保留待审批。真实 UI 点击开关双向写入通过，修正测试窗口高度与异步文件写入等待，不绕过真实点击。
- 尚未验证所有第三方 provider、超三模型及远程路径，不运行全套。

### 真实上游与应用验收

- 运行包第一轮 `dist/Abyss-portable-20261115-auto-dispatch`，使用用户原有模型池（本次查看为 GPT、DeepSeek、Kimi 三项，未修改模型池或凭据）。
- Test 会话中主代理自动选择 sonnet alias 对应 `@provider/gpt-6.1-sol`，无审批弹窗，新建一个 general-purpose 成员，实际返回 `AUTO=323`，零子工具调用。主模型未切换。
- 再请求同成员通过 SendMessage 回忆此前私有标记，新续接消息未重述标记；实际返回 `CEDAR-824`。宿主账本为一个成员、两次完成任务，未通过新建 Agent 冒充续接。
- 实际设置关闭自动模式，续接弹窗出现，点击取消；主代理确认未恢复、不重试或替代。初轮弹窗误用强制环境变量说明，最终包已改为绑定模型专属说明。
- 正常退出并启动最终包，手动模式偏好保持关闭。重新开启自动，再向同成员派工，仍正确回忆 `CEDAR-824`；账本实际 cliAgentId 未变，一个成员、三次完成任务。此次取消发生于首轮包，旧记录未关联成员，因此不把它作为最终版“已关联取消后拒绝续接”的实证；该修复只有定向测试证据。
- 截图已实际查看：`build/abyss-auto-live-{first,complete,continue,recalled}.png`、`abyss-auto-manual-continue.png`、`abyss-auto-final-settings.png`、`abyss-auto-restart-recalled.png`。
- 最终包 `dist/Abyss-portable-20261115-auto-dispatch-final/Abyss.exe`；app.so SHA-256 `C128C27ADB21041A6563B1941FC13B58597FFAEE31CCEDBD239FDD45A936ACAC`。Release 与身份检查通过，旧包保留。用户实例已正常切换并保持运行；原版 BaoCode 未关闭。
- 自动模式已恢复开启，左侧子代理列表仍隐藏；验收曾误关的提示建议开关已恢复原开启状态。没有更改模型池。

### 仍未完成

模型能力标签与基于事实的调度记录、成员待命/禁用管理 UI、完整任务证据卡、持久化并发排队与配置、跨 provider 有限故障切换、用户停止后的全调度路径防替代、通用停靠、浮动多屏、跨重启阅读锚点、范围冲突提示及执行记录面板均未完成。三次心算/记忆任务证明实际续接，不证明长期工程质量或持续高吞吐。
