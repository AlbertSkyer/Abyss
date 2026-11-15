# Abyss 产品目标与验收

## 交付约束

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

## 真实付费验收预算门禁

用户已批准真实验收费用上限人民币 5 元。只读检查确认 Abyss 有自己的三个 provider，未读取或输出密钥。DeepSeek 有公开定价，但 SkyLink 和 huilin 的首页及公开 pricing 路径未提供可确认的有效模型价格，无法可靠估算跨提供商验收费用，因此尚未发起任何真实付费请求。需要有效上游价格或服务端硬预算约束后再进行，不能将请求次数限制当成费用保证。

以下仍不能标为完成：真实交付包内两个并发子任务审批和不同上游路由、真实上游结果回主代理、真实上游 CLI 会话写入与整套窗口生命周期流程。后续按实际执行结果更新，不以代码存在或内置内核 mock 通过代替验收。
