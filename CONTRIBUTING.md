# 参与开发

本指南说明开发环境、资源维护、测试和提交方法。应用介绍见 [README](README.md)，界面约定见[设计规范](design/README.md)，模块与数据流见[架构设计](docs/native-architecture.md)。

## 开发环境

| 项目 | 要求 |
| --- | --- |
| 系统与 IDE | macOS、Xcode 26.6 |
| 模拟器 | 已安装的 iOS 26+ 运行时 |
| 维护工具 | Python 3.10+、Node.js 22+ |
| Swift 格式 | 根目录 `.swift-format` |
| Python 检查 | Ruff 0.14.14，规则位于 `pyproject.toml` |

模拟器不需要开发者账号。实体设备的 Team、证书和签名配置在本机维护，不提交个人设置、凭据或 `xcuserdata`。

## 构建与资源维护

使用 Xcode 打开 `JustMarkdown.xcodeproj`，选择 JustMarkdown scheme 构建运行。工程与共享 scheme 直接维护并提交；新增文件时核对目标归属、编译及资源阶段。

修改 WebSource、设计参数、品牌资源、离线依赖或阅读夹具后执行：

```sh
python3 scripts/build_native_web.py
python3 scripts/build_native_web.py --check
```

提交生成的 `Resources/Web`、`Resources/Sample`、`ReaderDesign.swift` 和品牌资源，不要直接修改生成文件。依赖更新见[离线依赖](vendor/README.md)，品牌母版、配色与生成位置见[品牌说明](design/brand/README.md)。

`python3 scripts/build_native_web.py --check --audit-dependencies` 额外联网检查固定 npm 版本的公开漏洞公告，CI 使用同一入口；普通构建和 `--check` 不联网。

界面翻译维护在 `JustMarkdown/Localizable.xcstrings`，系统权限说明维护在 `InfoPlist.xcstrings`。原生文案使用 SwiftUI 本地化 API 或 `String(localized:)`，由 Xcode 提取。新增或修改翻译后重新生成 Web 资源；生成器检查翻译是否完整、占位符是否一致及 Web 文案是否遗漏。验证时在 scheme 的 Application Language 中分别选择 English 和简体中文，并检查未支持语言的英文回退；不翻译文档内容和文件名。

隐私政策正文统一维护在 `docs/privacy.md` 的中英文部分；修改后运行同一资源生成器，提交供原生排版使用的政策内容。正文支持标题、段落、单段落无序列表、两列表格、加粗和链接；未支持的结构会中止生成，避免遗漏内容。应用中的政策入口不依赖网络，确认发送的授权按服务地址保存在设备上。

## 测试

测试按依赖环境管理。CI 使用 `JustMarkdown` scheme，真实模型使用独立的 `JustMarkdownLive` scheme；实体键盘和输入浮条由真机人工验证。

| 类型 | 维护位置 | 验证内容 | CI |
| --- | --- | --- | --- |
| 单元测试 | `JustMarkdownTests` | 文档、权限、上下文、协议解析、输入处理与撤销栈 | 在 iPhone、iPad 模拟器上运行 |
| WebKit 集成测试 | 同一目标中的 `WebReaderTests`、`AgentFlowTests` | 原生与 Web 同步、渲染、目录、编辑工具及模拟网络交互 | 在两端模拟器上运行 |
| UI 测试 | `JustMarkdownUITests` | 实际控件操作、软键盘、旋转、前后台切换及开合回归 | 在两端模拟器上运行 |
| 真实模型测试 | `JustMarkdownLiveTests` | 实际服务的两种协议、多轮对话、编辑及撤销重做 | 只编译，不发送请求 |
| 真机人工验证 | 本节的操作流程 | 实体键盘、输入浮条、手指与触控板、系统合成与设备恢复 | 不在托管流水线中运行 |

### 离线自动化测试

运行完整的单元、WebKit 集成和 UI 测试：

```sh
python3 scripts/verify_ios.py
```

脚本先生成资源并检查 JavaScript 语法、Swift 格式，使用 `build-for-testing` 编译一次，再选择已安装的最新 iOS 26+ 运行时。项目专用 iPhone／iPad 模拟器已存在则复用，缺少时创建；两端使用同一份测试产物执行 `test-without-building`。

Xcode 输出实时显示并保留完整日志，控制台可查看当前测试及结果。启用 XCTest 单项超时；连续 10 分钟没有输出时中断测试并收集诊断。CI 每个测试分组另设 15 分钟上限，预留时间上传失败产物。

| 参数 | 行为 |
| --- | --- |
| 不传参数 | 运行两端；产物写入 `output/native/` 下的本次运行目录 |
| `--family iPhone` / `--family iPad` | 只验证指定设备类型 |
| `--output /临时目录/本次运行` | 使用指定且尚不存在的产物目录 |
| `--suite unit` / `--suite ui` | 分别运行单元／集成目标或 UI 目标；默认运行全部 |
| `--shard-index 0 --shard-count 4` | 运行所选目标的一个分组，索引从零开始 |
| `--test-products /临时目录/Products` | 使用同版本 Xcode 构建的可迁移测试产物，不重复构建或检查源码 |
| `--ci-matrix` | 输出流水线所需的完整任务矩阵，不运行测试 |

分组从 Xcode 对编译产物的测试发现结果生成，不维护人工用例清单。每组按稳定顺序分配，新增用例自动参与；禁用用例、发现错误、空分组、实际运行数量与分配数量不一致均导致失败。每次运行保存发现结果、分组计划和结果计数，便于核对完整性。

这些测试只使用模拟网络或本机端口，不连接真实模型服务，不需要外部 API Key。测试凭据与正常 App 隔离，结束删除测试记录。未经维护者明确许可，不得跳过测试或通过排除必测用例绕过失败；环境或配置不足应报告为验证阻塞。脚本要求所有用例通过且跳过数为零。

其他静态检查：

```sh
ruff check scripts
ruff format --check scripts
python3 -m unittest discover -s scripts/tests
```

[GitHub Actions](.github/workflows/verify.yml) 配置凭据扫描、格式与资源检查、Release 编译、真实模型测试目标的编译及两端离线回归。主构建作业打包一次模拟器测试产物；每种设备的单元／集成测试独立运行，UI 测试分为四组，分别在独立 runner 上并行执行。完整矩阵由验证脚本统一生成，任意一组失败都会使流水线失败，其余分组继续执行。脚本的测试发现与分组规则由 `scripts/tests/` 下的标准库单元测试验证。托管 runner 不连接开发者的真机，也不配置真实模型密钥；结果以对应工作流运行为准。

Debug 的 `--sample-document` 打开长文副本，`--reset-sample-document` 重置副本；入口与样例不编入 Release。文件授权相关变更应经系统选择器打开外部文档复测，输入相关变更应核对对应的软件／实体键盘路径。

### 真实模型测试

选择 `JustMarkdownLive` scheme，运行 [LiveModelTests.swift](JustMarkdownLiveTests/LiveModelTests.swift) 的 `testAtlasProtocolsConversationAndSourceEdit`。该目标仅接受 HTTPS Atlas 端点，缺少配置时测试失败，不自动跳过或降级为模拟请求。

1. 在仓库外准备权限为 `0600` 的私有 JSON 文件，包含 `baseURL`、`model`、`key`，以及可选的 `apiProtocol`（`responses` 或 `chatCompletions`；省略时分别测试两种协议）。
2. 将 `JustMarkdownLive` 复制为本机非共享 scheme，在 Test → Arguments 中维护本机环境变量；Test 不沿用 Run 的参数与环境变量。
3. 添加 `JUSTMARKDOWN_LIVE_CONFIG` 指向配置文件，设置 `CFNETWORK_DIAGNOSTICS=0`。
4. 分别选择 iPhone 与 iPad 模拟器运行该 scheme。

选择支持工具调用的模型与接口组合；只验证一种协议时填写 `apiProtocol`。实体设备运行时，将配置文件放入测试宿主 App 的沙盒，环境变量支持以 `~/` 开头的应用内路径。

测试使用独立样本文档和 Keychain 服务，结束删除测试凭据。真实调用可能计费；不提交私有 scheme、配置路径、凭据或包含它们的附件。

### 真机人工验证

使用普通 App 启动方式运行 Debug，退出 XCTest 和调试断点后操作设备。`--sample-document --reset-sample-document` 准备独立长文副本；添加 `--ui-testing --ui-test-agent-fixture` 可使用隔离配置和模拟回答，离线检查 AI 界面与按键流程。文件授权检查应另用独立目录，经系统文件选择器打开。

1. 源码中用实体键盘输入和确认中文候选，用方向键移动光标、Enter 换行，检查滚动和内容；用 ⌘Z、⇧⌘Z 撤销重做，再编辑以确认旧重做分支失效。
2. AI 输入中检查 Enter 发送一次、Shift＋Enter 换行；候选确认和长按重复不误发送。切换软键盘后，回车只换行，发送按钮提交。
3. 分别显示停靠软键盘、浮动键盘和实体键盘输入浮条。完整停靠键盘缩短内容视口，局部浮条不产生整页底部白边；底部操作保持可点击并避让输入界面。
4. 用手指和触控板分别反复展开、收起底部操作，并在快速反向操作后再次收起；展开动作保持同一高度，组外仍可操作正文。
5. 在两个横屏方向和竖屏之间切换，继续在源码与 AI 输入区输入，确认内容、阅读位置和控件布局正确。
6. 重复切到其他 App 再返回，检查正文、目录、滚动和输入；锁屏解锁及重新连接键盘后再次检查。

真机检查结果记录在对应 PR 或 Issue，注明构建版本、设备、系统、键盘及实际操作结论。CI 通过不代表这些检查已经完成；未执行或失败的项目仍需补验，不能记为通过。

## 提交修改

说明问题、最终行为、实际检查和剩余限制。功能与交互变更先说明场景和预期，修复不夹带无关重构、依赖升级或界面改版。涉及平台交互时分别验证 iPhone 与 iPad；模拟器和模拟网络结果不能代替真机或真实服务验证。安全问题按 [SECURITY.md](SECURITY.md) 私下反馈。

公开文档服务于用户使用和贡献者维护。同一规则由对应文件负责，其他位置通过链接引用；操作用编号，比较用表格，标识符和命令使用代码格式。测试运行结果放在 CI／PR，具体缺陷通过 Issue 跟踪，不提交验收进度、排查经过或历史测试计数。

`scripts/` 只保留可重复执行的维护工具，稳定回归进入测试目标。单次探针、构建缓存、日志、xcresult 和评审截图放在可删除的临时目录，完成核对后清理。不要提交真实文档、原始模型请求／回复或含凭据的截图。
