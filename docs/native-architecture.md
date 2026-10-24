# 架构与维护约束

JustMarkdown 使用 SwiftUI／UIKit 原生容器与 WKWebView 离线渲染，部署基线为 iOS / iPadOS 26、Swift 6。本文面向修改代码的贡献者；应用介绍见 [README](../README.md)，构建与测试见[贡献指南](../CONTRIBUTING.md)。

## 模块分工

| 模块 | 职责 |
| --- | --- |
| `ReaderScreen` / `ReaderWebView` | 原生操作、模态、系统选择菜单、WebKit 容器与桥接生命周期 |
| `ReaderSession` / `MarkdownDocument` / `LocalResources` | 当前文档、原位置保存、编码、目录授权、相对资源和取消 |
| `RecentDocumentsStore` / `RecentDocumentsView` | 本地最近文档、系统书签、授权恢复与自适应列表 |
| `ModelConnection` / `ModelClient` / `ModelWireFormat` | 连接配置、Keychain、URLSession、Responses／Chat 与流解析 |
| `ModelSettingsView` / `ModelSelectionView` / `ModelCatalog` | 设置、模型列表及按连接隔离的内存缓存 |
| `AgentContextBuilder` / `AgentModelTransport` | 完整上下文、版本映射、请求快照、生成与恢复 |
| `AgentDocumentTools` / `ModelTools` | 工具声明与回放、当前文件版本验证、原子编辑与保存 |
| `NativeComposerHost` / `ConversationInput` | UIKit 输入、物理按键、输入法组合与草稿同步 |
| `WebSource/` | 正文与 Agent 共用的解析、排版、选段转换、导航、动效及源码历史 |
| `Localizable.xcstrings` / `InfoPlist.xcstrings` | 界面与系统权限文案的中英文翻译 |

Swift 持有文件、凭据、网络与物理键盘能力，Web 负责显示和交互适配。API Key 不进入 WebKit。渲染与数据边界见[隐私政策](privacy.md)。

界面跟随系统为 App 选择的语言，支持英文与简体中文，以英文回退。原生使用 String Catalog；构建脚本从同一目录生成 Web 翻译，WebKit 在页面加载前接收 App 的语言选择。只翻译应用自己的文案，保留文档、文件名、引用及模型回复的原始内容。

[PrivacyInfo.xcprivacy](../JustMarkdown/PrivacyInfo.xcprivacy) 声明不跟踪，并以 `CA92.1` 将 UserDefaults 用于本 App 的设置与最近文档记录。平台隐私清单、面向用户的[隐私政策](privacy.md)及 App Store Connect 的隐私信息各有用途；修改数据流时需分别核对。

## 渲染与资源生成

预览、目录和源码共用 WKWebView 中的 Markdown 缓冲区。解析器源码范围用于双向位置映射，源码编辑采用 WebKit 文本输入。

| 维护源 | 生成结果 |
| --- | --- |
| `JustMarkdown/WebSource/` 与固定 `vendor/` 资源 | `JustMarkdown/Resources/Web/` |
| `design/tokens.json` | Web 样式与动效参数、`JustMarkdown/ReaderDesign.swift` |
| `design/brand/mark.svg` 与 `brand.json` | `design/brand/production/`、首页矢量和配色资源，见[品牌说明](../design/brand/README.md) |
| `JustMarkdownTests/Fixtures/ReadingGuide/` | `JustMarkdown/Resources/Sample/`，仅 Debug 打包 |

`build_native_web.py` 校验依赖摘要后完整生成资源，`--check` 只读比较。生成文件不反向充当源码。版本、许可证和文件摘要由 [vendor/assets.json](../vendor/assets.json) 管理。

## 文件与编辑

资源路径相对于 Markdown 的父目录解析，包含 `../`；展开符号链接后检查用户授权范围。资源读取通过后台 NSFileCoordinator，已取消的 WebKit 请求不再回调。授权提示等待全文资源清单，计算共同父目录，避免消息到达顺序影响授权位置。缺失文件不当作权限不足处理。文件 scope 在关闭时释放，目录 scope 随阅读会话释放。

文档扩展名由 `MarkdownDocument.supportedFilenameExtensions` 定义，选择器复用此列表；共同打开入口在读取或切换文档前校验类型，覆盖外部 URL 和最近记录。系统文档类型声明与该列表保持一致；这一限制不影响正文引用资源的加载。

UIDocument 原位置自动保存；切换模式、换文件和进入后台前刷新缓冲区。保存失败保留当前内容供重试，新文件打开失败保留原文档。保存完成回调与 `handleError` 共同结束挂起操作，关闭遵循先保存、成功后再关闭的顺序。

最近文档在成功打开后更新，按文件去重并保留最近 10 项。UserDefaults 保存文件位置、系统书签与已授权的资源目录书签，不保存正文副本。书签创建和解析在后台执行，禁用解析时的系统交互和隐式授权启用；原生会话显式启用访问，并在失败或会话结束时配对释放。重开成功后更新书签和文件名；失效文件保留在列表中并提示错误，其他记录仍可选择。

支持 UTF-8、带 BOM 的 UTF-16 和 GB18030。缓冲区统一 LF，写入保留原换行约定、BOM 与 UTF-16 字节序；混合换行编辑后使用首次出现的约定。未编辑的文件不因打开或切换视图回写。

手动输入、组合输入、粘贴和 AI 批次共用 `source-history.js` 历史。一次 AI 批次对应一个事务；新编辑清空重做，切换模式保留历史，换文件重置。会话修改状态以历史事件为准，迟到的保存确认不能覆盖后续撤销／重做。

## 交互约束

- 首页展示标志、小写 slogan、打开文档主按钮及其下方的“最近打开...”次级文字按钮；slogan 整句使用相同样式，宽度足够时显示一行，窄屏按语义换行并适应大字号。同一个有序元素集合决定布局与从上到下的滑入渐显顺序，开启 Reduce Motion 时直接显示。最近列表复用同一组件：紧凑布局为可调整高度的 sheet，宽布局为锚定入口的 popover。阅读页使用共享悬浮操作，不设顶栏或额外产品模式。手机折叠操作、宽布局直接显示；更多仅包含模型设置，关闭文档先保存再返回首页。
- 模式切换跟随视口顶部内容，在目标布局和图表准备后定位再淡入。不滚动的往返保持语义锚点，图片／字体重排在用户继续交互前保持阅读位置。
- 目录收起不占正文宽度。章节变化平滑跟随当前行，快速更新从当前位置与速度衔接；手动浏览暂停跟随，重新操作正文或重开目录恢复。折叠分支以可见祖先表示当前项。
- 预览与源码共用一个系统选择菜单 AI 入口，不叠加网页选段按钮。全局入口使用当前文档，不能沿用放弃的选段；已发送引用保持不变。
- 源码也能辅助阅读；只有明确编辑要求才授权修改。预览只读，遇到修改要求引导用户去源码，不自动切换。软件 Return 换行，实体 Enter 发送、Shift＋Enter 换行；输入法确认、按键重复与生成中的新草稿不能误提交。
- 组件所有权、引用布局、表格裁切、模态阻塞和反馈状态由 [components.json](../design/components.json) 维护；视觉与动效参数由 [tokens.json](../design/tokens.json) 维护，支持 Reduce Motion 与快速反向。

## Agent 上下文与工具

选段是关注点，全文提供背景。用户请求与引用分别编码为 `request`、`reference`；引用保留实际内容及所属 `documentID`。最后一轮 `background.documents` 按内容去重保存完整版本，`background.currentDocumentID` 标识发送时版本。当前全文和旧选段可能属于不同版本，不能互相冒充。不静默截断全文、丢弃历史或自动摘要。

文档与引用作为材料，不具有指令权限。文件名只保留最后一级，不额外发送系统绝对路径、授权根目录、访问令牌或源码坐标；正文自带的路径仍属于内容。不读取其他文件或自动上传图片。完整数据流见[隐私政策](privacy.md)。

源码仅提供 `read_document` 与 `edit_document`，没有路径参数或目录、网络、Shell 工具。编辑验证当前 SHA-256 revision，批次非空，每项 `before` 必须唯一且逐字相符，范围互不重叠；仅空文档允许空 `before`。全部通过后原子应用并保存。会话显示实际变化与保存状态；普通回答或 JSON 不构成文件修改。

工具参数在整轮成功完成后才执行。逐项记录结果，后续失败或停止保留已完成修改，重试从结果日志继续，不重复编辑。循环保护检查相同调用、相同结果且文档没有变化，不设置固定轮数。修改卡片不能越过历史顺序覆盖后续编辑。

打开面板不发送请求，收起保留会话与生成，停止才取消；换文档取消并隔离旧回调。UIKit 输入通过草稿 epoch 拒绝过期回调，提交先同步原生文本。重试复用原问题、引用和历史快照，保留当前草稿及部分回答，直到替换内容到达；仅最新失败轮次可重试。

## 模型传输

请求只使用明确选择的协议，不探测或自动回退。Responses 将系统指令放入 `instructions`，完整历史放入 `input`，设置 `store:false`，不依赖服务器会话；Chat 使用相应消息与工具封装。服务端数据保留由提供方决定。

两种协议解析 SSE 与非流式 JSON，处理分片 UTF-8、CRLF、心跳、取消及异常结束。Responses 以 `response.completed` 为成功终点；失败或不完整事件不视为成功。Chat 处理 `finish_reason` 和 `[DONE]`。推理内容不作为正文显示。

源码工具使用 strict schema，字段全部 required，禁止额外字段，设置 `parallel_tool_calls:false`；本地仍串行校验。后续请求保留协议所需的工具结果和 opaque reasoning／签名字段。Chat 后续空／null 身份字段不能覆盖首片信息，缺失或重复的最终调用 ID 拒绝执行。

模型列表按端点与 Key 摘要隔离内存缓存，连接变化取消过期请求，迟到结果不覆盖新连接。选择页共享在途请求并保留独立快照，后台刷新不改变当前列表；整个设置模态关闭后清理输入中的 Key。凭据只持久化到 Keychain。
