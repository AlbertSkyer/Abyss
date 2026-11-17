# Abyss 浏览器扩展（Windows / Chrome / Edge）

Abyss 扩展与原版 BaoCode 使用不同扩展 ID、本地通信宿主和标签组，可同时安装。当前为离线开发者模式版本，未上架商店。

## 安装

1. 安装包含浏览器宿主的新版完整 Abyss Windows 包；单独复制 Abyss.exe 不够。从 1.9.10（36）起提供此功能；1.9.9 及更早版本不支持此独立扩展。
2. 在 Abyss 设置 → 浏览器，点击“打开扩展目录”。目录包含 manifest.json，请长期保留。
3. Chrome 打开 `chrome://extensions`；Edge 打开 `edge://extensions`。
4. 开启“开发者模式”，选择“加载已解压的扩展程序”，选取上述 unpacked 目录。
5. 将 Abyss 扩展固定到工具栏，保持 Abyss 运行；设置页应显示浏览器已连接。

也可将 Abyss-browser-0.1.0.zip 解压到长期保留目录，再加载其中直接包含 manifest.json 的目录。ZIP 不是双击安装的 CRX。离线扩展需手动更新并在扩展管理页点击“重新加载”。升级 Abyss 后可继续使用安装目录中的相同路径。

便携包默认不写浏览器注册表，只有扩展目录不代表宿主已注册；一般用户应使用 setup 安装。不要导入 BaoCode 的注册项来连接 Abyss。

## 使用边界

- 点击工具栏 Abyss 按钮主动共享/取消共享当前标签；Abyss 分组内的标签才可被浏览器工具读取和控制。工具可以在自己的分组打开新标签。
- BaoCode 分组、普通标签不自动共享给 Abyss。两个扩展权限独立，不复用凭据。
- 扩展使用 debugger 权限，浏览器会显示调试提示；不要关闭安全保护。访问本地 file:// 还需要你在扩展详情单独允许。
- 在 Abyss 设置关闭浏览器功能后，连接和工具停止；临时聊天仍禁用工具与 MCP。
- 企业管理策略可能禁止开发者模式、扩展或 Native Messaging。本项目不绕过这些限制。

## 独立身份与隐私

- 扩展 ID：`kecjiojfloffimkeghgongilhienkdlh`
- 宿主：`dev.abyss.browser`
- Windows 程序：`abyss-browser-host.exe`
- 共享分组：`Abyss`
- 本地连接仅使用 loopback、随机令牌及精确扩展 origin 校验，端点与 BaoCode 分离。

仅共享你愿意让代理访问的页面；共享页面可能含登录状态和个人信息。验证或故障排查不要发送 Cookies、令牌、浏览器完整 profile 或模型密钥。

## 构建与许可

基于仓库 browser_extension 的同一 MV3 实现生成独立身份，不维护第二套 CDP 协议。使用 `node tool/build_abyss_extension.mjs --out <全新目录>` 构建离线版本。Abyss 身份配置只含公开 key；私钥不属于扩展/安装包，也不应提交仓库。

修改版遵循仓库 GPL-3.0，保留来源与版权通知；对应源码位于 https://github.com/AlbertSkyer/Abyss ，原项目 https://github.com/baocode-dev/baocode 。这是独立修改版，不是原版 BaoCode 官方扩展。
