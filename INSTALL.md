# 安装与使用

Paragraph Translator is an experimental macOS menu bar app. It translates selected English into Simplified Chinese using your own local Codex sign-in.

本工具不包含 Codex CLI 或任何人的登录信息。你需要在自己的 Mac 上安装 Codex，并登录自己的 ChatGPT 账号；翻译使用你账号的 Codex 额度，原文会发送给模型处理。

## 安装前确认

- 现成下载包只适用于 **Apple Silicon Mac（M 系列芯片，arm64）**，不适用于 Intel Mac。
- 应用声明的最低系统版本为 **macOS 14**，目前只在 **macOS 27** 做过实际运行验收。较旧系统、其他来源应用的选区兼容性仍需验证。
- 当前固定使用 **`gpt-6-luna` / `low`**，需要你的 Codex 客户端和账号有权使用这个模型；企业工作区可能需要管理员开启。应用内暂时没有模型切换设置。
- 本预览版使用本地临时签名，**未做 Apple Developer ID 签名或公证**。首次打开可能被 macOS 拦截。

模型访问权取决于账号、客户端和工作区，不能通过本地指定模型获得权限。参见 [OpenAI 模型权限说明](https://learn.chatgpt.com/docs/enterprise/workspace-model-availability)。

## 1. 安装 Codex，登录自己的账号

如果已经安装 [Homebrew](https://brew.sh/)，在终端运行：

```bash
brew install --cask codex
codex --version
codex login
codex login status
```

`codex login` 会打开浏览器，请用自己的 ChatGPT 账号完成登录。`codex login status` 用来确认当前登录方式；要使用 ChatGPT 订阅额度，应确认它显示的是 ChatGPT 登录，而非 API Key 登录。

已有 Codex CLI 可跳过安装。需要更新 Homebrew 安装的 CLI 时运行：

```bash
brew upgrade --cask codex
```

没有 Homebrew，也可以按照 [OpenAI 官方 CLI 安装指南](https://learn.chatgpt.com/docs/codex/cli) 安装。使用 standalone、npm 或自定义目录时，请同时阅读下方“找不到 Codex CLI”。

可在终端运行 `codex`，通过 `/model` 查看自己的客户端提供的模型。当前应用会固定请求 `gpt-6-luna`，在其他 Codex 聊天里选择不同模型不会改变本应用的模型。若 Luna 不可用，需要先解决账号或工作区访问权限。

登录缓存由你本机的 Codex 管理。**不要下载别人的登录文件，也不要将自己的登录文件、令牌或 API Key 发给别人。** 参见 [OpenAI 登录与凭据说明](https://learn.chatgpt.com/docs/auth)。

## 2. 下载并打开应用

当前预览版本为 **`v0.1.2-preview`**，下载文件为：

```text
paragraph-translator-0.1.2-macos-arm64.zip
```

从 [GitHub Releases](https://github.com/linjiongxie/paragraph-translator/releases) 或 [v0.1.2-preview 发布页](https://github.com/linjiongxie/paragraph-translator/releases/tag/v0.1.2-preview) 下载。GitHub 的 [latest 链接](https://github.com/linjiongxie/paragraph-translator/releases/latest) 通常指向正式版；只有预览版时，请使用前面的 Releases 列表。

1. 解压 ZIP，将 **“段落翻译.app”拖入“应用程序”（`/Applications`）**。
2. 从“应用程序”打开“段落翻译”。启动后，顶部菜单栏会出现对话气泡图标；这是菜单栏工具，没有常驻 Dock 图标。
3. 若 macOS 提示无法验证开发者或无法检查恶意软件，先确认文件来自上述仓库且未被篡改。若你决定运行它，按 Apple 官方说明，在尝试打开之后进入 **系统设置 → 隐私与安全性 → 仍要打开**，再确认打开。

不要为了运行本工具关闭全局 Gatekeeper。系统或单位管理策略可能不允许添加例外；可参考 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/en-us/102445)。

## 3. 授权选区读取并翻译

1. 在本工具浮窗点“去授权”，进入 **系统设置 → 隐私与安全性 → 辅助功能**。在 macOS 27 中，这一页面名称可能显示为 **“设备控制和数据访问”**。
2. 开启“段落翻译”。列表中没有它时，点 `+`，选择“应用程序”中的“段落翻译.app”。只需要处理本工具的权限条目。
3. 切回阅读的应用，选中一段英文，实际按下 **⌥⌘T（Option + Command + T）**。
4. 译文会在浮窗中逐步出现；完整翻译与格式校验完成后，可点“复制译文”。按 Esc 或关闭浮窗会取消当前请求。

工具只在你触发后读取选区；正常取词不会模拟复制或覆盖剪贴板。段落、列表和强调格式取决于来源应用提供的信息。无法读取排版时会提示回退到纯文本；扫描 PDF、图片和不暴露选中文字的界面暂不支持。

**不想授予跨应用读取权限，也可以使用手工输入：** 点击菜单栏图标 → **“输入或粘贴英文…”**，输入或粘贴英文后翻译。这个入口无需辅助功能权限，但仍需要 Codex 登录、模型权限和网络连接。

### Markdown 表格与窗口缩放

从 **`v0.1.1-preview`** 起支持 Markdown 表格（旧版 `v0.1.0-preview` 不包含此功能）。可通过手工输入入口粘贴 Markdown 表格；需要有表头和 `| --- |` 分隔行。译文逐单元格出现，未翻译的单元格暂时留空，数字、行列和对齐由程序保留。宽表格可横向滚动。

跨应用取表需要来源应用提供辅助功能表格与单元格信息。请完整选中一张普通、没有合并单元格的表格，再按 ⌥⌘T；已完成一个 Claude 整表来源的独立捕获验证，兼容性仍取决于来源应用。只选部分表格、存在合并单元格或无法读取表格元数据时，会回退到纯文本并提示；可改用手工粘贴原始 Markdown。

表格较大时，可拖动窗口边缘或右下角斜线手柄放大，译文区域会随窗口伸缩；手柄悬停时显示缩放光标和“拖动调整窗口大小”提示。缩小后仍可滚动查看内容。窗口设有最小尺寸，避免按钮被挤掉。同一次运行中，关闭浮窗再打开会保留调整后的尺寸。

## 常见问题

### 显示“未找到 Codex CLI”

先在终端检查：

```bash
command -v codex
codex --version
```

从 Finder 打开的应用不一定继承终端的 shell PATH。目前应用会检查自身进程的 PATH、ChatGPT/Codex 桌面应用的常见内置位置，以及 `/opt/homebrew/bin/codex`、`/usr/local/bin/codex`。

因此，“终端中能运行”不一定代表本工具能找到。建议使用官方 Homebrew 安装方式；npm、版本管理器或其他自定义目录可能需要另行适配。应用目前没有选择 CLI 路径的界面。安装后退出并重新打开“段落翻译”。

### Codex 登录、额度或模型报错

- 运行 `codex login status` 确认自己当前的登录方式；需要重新登录时运行 `codex login`。
- 确认账号和所选工作区可使用 `gpt-6-luna`。企业工作区请向管理员确认模型权限。
- 网络、账号额度和工作区管理策略都会影响翻译。应用当前单次超时为 60 秒，原文最多 20,000 字符。
- 关闭浮窗会取消请求，但不代表已消耗的模型额度会返还。

### 报 app-server、通信协议或 feature 错误

当前实际验证的 Codex CLI 为 **`0.163.0-alpha.10.2`**。这是验证记录，不代表其他版本一定不兼容，也不是已验证的最低版本。

本工具使用 Codex app-server 的独立 stdio 会话，协议和功能配置可能随 CLI 版本变化。升级 CLI 或桌面应用后出现错误，请在 [GitHub Issues](https://github.com/linjiongxie/paragraph-translator/issues) 提供 macOS 版本、Mac 芯片、`codex --version` 和去除敏感信息后的错误文字。不要附上原文、完整配置、登录文件或令牌。

协议依据：[OpenAI Codex App Server](https://learn.chatgpt.com/docs/app-server)。

### 已授权，仍然取不到选区

先用菜单栏的手工输入入口验证翻译后端，再检查以下事项：

- 是否给“应用程序”中的当前这份 App 授权，并在原应用中保留选区后按 ⌥⌘T。
- 更新或自行重新编译会改变临时签名。若旧权限不再生效，只移除“段落翻译”条目，重新添加当前 App 并开启，然后重启工具。
- 某些应用不提供可读取的选区或格式；可改用手工输入或粘贴。当前已验证的 Claude 场景不代表所有浏览器、PDF 查看器和 Electron 应用都兼容。
- 若系统提示快捷键注册失败，请检查是否有其他软件占用了 ⌥⌘T；也可先使用菜单栏入口。

辅助功能权限说明：[Apple：允许辅助功能 App 访问 Mac](https://support.apple.com/en-euro/guide/mac-help/mh43185/mac)。

### Terminal 内的 Claude Code：有高亮却读不到

Claude Code 全屏界面的普通拖选可能由 Claude Code 自己处理，没有进入终端的系统选区；这种高亮无法通过本工具使用的辅助功能选区接口读取。请先使用终端原生选区：

- macOS 自带 Terminal：按住 **Fn（🌐）** 拖选英文，松开鼠标和 Fn 后，再按 **⌥⌘T**。
- iTerm2：官方文档给出的原生拖选修饰键为 **Option**；本工具尚未完成 iTerm2 实机验收。
- 需要保留 Claude Code 自身选取方式时，可明确复制所选文字，然后点菜单栏 **“翻译剪贴板中的英文”**。本工具不会在取词失败后自动读取旧剪贴板。

原生拖选方式来自 [Claude Code 官方文档](https://code.claude.com/docs/en/fullscreen#keep-native-text-selection)。2026-10-23 本机实际操作确认 **Fn 拖选后可通过 ⌥⌘T 整段翻译**；此次测试中 Terminal 的“允许鼠标报告”处于关闭状态，其他配置和版本仍需验证。仅关闭“显示 → 允许鼠标报告”时，双击选词可用但普通整段拖选仍失败，因此关键使用方式是 Fn 拖选。关闭鼠标报告还会影响 Claude Code 的鼠标交互。

终端选区按纯文本读取；Claude Code 用线条字符画出的表格不会自动转为 Markdown 表格。若需要保留表格网格，请复制原始 Markdown 表格后通过手工输入入口翻译。

## 从源码构建

需要 macOS、Swift 6 或更高版本，以及提供 macOS 26 新辅助功能常量的 SDK。建议安装最新稳定版 Xcode 或相应 Command Line Tools。应用运行的最低系统声明与构建所需 SDK 是两回事；旧 SDK 即使支持 Swift 6，也可能无法识别源码中的新常量。

```bash
git clone https://github.com/linjiongxie/paragraph-translator.git
cd paragraph-translator
swift --version
xcrun --show-sdk-path
swift test
bash scripts/test-web-selection.sh
bash scripts/test-terminal-selection.sh
bash scripts/build-app.sh
```

生成结果为 `dist/段落翻译.app`。将它拖入“应用程序”再启动，并按上述流程授权。构建脚本会使用本机架构并添加临时签名；它不会把 Codex CLI 或登录信息打进 App。

Intel Mac 可尝试从源码构建本机架构，但目前没有 Intel 的构建与运行验收，不能用现成 arm64 ZIP 替代。重新构建或更换 App 后，可能需要重新添加该 App 的辅助功能授权。

项目主页：[linjiongxie/paragraph-translator](https://github.com/linjiongxie/paragraph-translator)。
