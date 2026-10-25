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

界面翻译维护在 `JustMarkdown/Localizable.xcstrings`，系统权限说明维护在 `InfoPlist.xcstrings`。原生文案使用 SwiftUI 本地化 API 或 `String(localized:)`，由 Xcode 提取。新增或修改翻译后重新生成 Web 资源；生成器检查翻译是否完整、占位符是否一致及 Web 文案是否遗漏。验证时在 scheme 的 Application Language 中分别选择 English 和简体中文，并检查未支持语言的英文回退；不翻译文档内容和文件名。

隐私政策正文统一维护在 `docs/privacy.md` 的中英文部分；修改后运行同一资源生成器，提交供原生排版使用的政策内容。正文支持标题、段落、单段落无序列表、两列表格、加粗和链接；未支持的结构会中止生成，避免遗漏内容。应用中的政策入口不依赖网络，确认发送的授权按服务地址保存在设备上。

## 测试

运行单元、WebKit 集成与原生 UI 测试：

```sh
python3 scripts/verify_ios.py
```

脚本先生成资源并检查 JavaScript 语法、Swift 格式，再选择已安装的最新 iOS 26+ 运行时。项目专用 iPhone／iPad 模拟器已存在则复用，缺少时创建。

| 参数 | 行为 |
| --- | --- |
| 不传参数 | 运行两端；产物写入 `output/native/` 下的本次运行目录 |
| `--family iPhone` / `--family iPad` | 只验证指定设备类型 |
| `--output /临时目录/本次运行` | 使用指定且尚不存在的产物目录 |

普通测试使用模拟网络或本机端口，不连接模型供应商。需要真实服务或实体键盘环境的用例可能跳过；提交时区分通过、失败、跳过和未测。测试凭据与正常 App 隔离，结束删除测试记录。

其他静态检查：

```sh
ruff check scripts
ruff format --check scripts
```

[GitHub Actions](.github/workflows/verify.yml) 配置凭据扫描、格式与资源检查、Release 编译及两端回归；结果以对应工作流运行为准。

Debug 的 `--sample-document` 打开长文副本，`--reset-sample-document` 重置副本；入口与样例不编入 Release。文件授权相关变更应经系统选择器打开外部文档复测，输入相关变更应核对对应的软件／实体键盘路径。

### 真实模型测试

入口是 [AgentFlowTests.swift](JustMarkdownTests/AgentFlowTests.swift) 的 `testLiveAtlasProtocolsConversationAndSourceEdit`。该用例仅接受 HTTPS Atlas 端点，未提供配置时跳过。

1. 在仓库外准备权限为 `0600` 的私有 JSON 文件，包含 `baseURL`、`model`、`key`，以及可选的 `apiProtocol`（`responses` 或 `chatCompletions`；省略时分别测试两种协议）。
2. 复制本机非共享 Xcode scheme，在 Test → Arguments 取消沿用 Run 的参数与环境变量。
3. 添加 `JUSTMARKDOWN_LIVE_CONFIG` 指向配置文件，设置 `CFNETWORK_DIAGNOSTICS=0`。
4. 从测试导航器只运行上述用例，分别选择 iPhone 与 iPad 模拟器。

测试使用独立样本文档和 Keychain 服务，结束删除测试凭据。真实调用可能计费；不提交私有 scheme、配置路径、凭据或包含它们的附件。

## 提交修改

说明问题、最终行为、实际检查和剩余限制。功能与交互变更先说明场景和预期，修复不夹带无关重构、依赖升级或界面改版。涉及平台交互时分别验证 iPhone 与 iPad；模拟器和模拟网络结果不能代替真机或真实服务验证。安全问题按 [SECURITY.md](SECURITY.md) 私下反馈。

公开文档服务于用户使用和贡献者维护。同一规则由对应文件负责，其他位置通过链接引用；操作用编号，比较用表格，标识符和命令使用代码格式。测试运行结果放在 CI／PR，具体缺陷通过 Issue 跟踪，不提交验收进度、排查经过或历史测试计数。

`scripts/` 只保留可重复执行的维护工具，稳定回归进入测试目标。单次探针、构建缓存、日志、xcresult 和评审截图放在可删除的临时目录，完成核对后清理。不要提交真实文档、原始模型请求／回复或含凭据的截图。
