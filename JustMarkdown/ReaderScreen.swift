import SwiftUI
import UniformTypeIdentifiers

private enum ReaderAccessibilityAction { case tools, ai, more, open, recents }
private enum HomeItem: CaseIterable, Hashable {
    case mark, slogan, openDocument, recentDocuments

    var spacingBefore: CGFloat {
        switch self {
        case .mark: 0
        case .slogan: ReaderDesign.homeBrandGap
        case .openDocument: ReaderDesign.homeGroupGap
        case .recentDocuments: ReaderDesign.homeActionGap
        }
    }
}

struct ReaderScreen: View {
    private let homeSlogan = ["just markdown.", "pure reading."]
    @ObservedObject var session: ReaderSession
    @State private var modelSettingsPresented = false
    @State private var importing = false
    @State private var importingFolder = false
    @State private var toolsExpanded = false
    @State private var modelSettingsSaved = false
    @State private var visibleHomeItems: Set<HomeItem> = []
    @State private var recentsPresented = false
    @AccessibilityFocusState private var focusedAction: ReaderAccessibilityAction?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var markdownTypes: [UTType] {
        MarkdownDocument.supportedFilenameExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if session.document == nil {
                    welcome(viewport: geometry.size)
                        .transition(.opacity)
                } else {
                    ZStack {
                        ReaderWebView(session: session)
                            .simultaneousGesture(TapGesture().onEnded { toolsExpanded = false })
                        if !session.rendererReady { ProgressView().accessibilityLabel("正在排版文档") }
                    }
                    .overlay(alignment: .topLeading) {
                        if session.mode == "preview" && !session.agentModalActive {
                            Button {
                                session.toggleOutline()
                            } label: {
                                Image(systemName: "sidebar.left").font(.system(size: ReaderDesign.outlineIcon))
                                    .frame(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget).contentShape(
                                        Circle())
                            }
                            .modifier(ReaderGlassControl()).foregroundStyle(.secondary)
                            .padding(.leading, 8).padding(.top, 16)
                            .accessibilityLabel(session.outlineExpanded ? "收起文章目录" : "展开文章目录")
                            .accessibilityIdentifier("OutlineToggle")
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if !session.agentModalActive {
                            Button {
                                toolsExpanded = false
                                Task { await session.closeDocument() }
                            } label: {
                                actionIcon("xmark", compact: true)
                            }
                            .modifier(ReaderGlassControl()).foregroundStyle(.secondary)
                            .padding(
                                .trailing,
                                session.agentOpen && geometry.size.width >= 900 ? ReaderDesign.agentWidth + 32 : 8
                            )
                            .padding(.top, 16)
                            .accessibilityLabel("关闭当前文档")
                            .accessibilityIdentifier("CloseDocument")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !session.agentModalActive {
                            floatingActions.padding(
                                .trailing,
                                session.agentOpen && geometry.size.width >= 900 ? ReaderDesign.agentWidth + 32 : 16
                            )
                            .padding(.bottom, 16)
                        }
                    }
                    .allowsHitTesting(!session.isClosingDocument)
                    .accessibilityHidden(session.isClosingDocument)
                    .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: ReaderDesign.contentDuration), value: session.document == nil
            )
            .onChange(of: session.document == nil) { _, empty in
                if empty {
                    toolsExpanded = false
                    focusedAction = .open
                }
            }
            .onChange(of: session.agentOpen) { _, open in
                if open {
                    toolsExpanded = false
                } else if !session.agentModalActive {
                    focusedAction = horizontalSizeClass == .compact ? .tools : .ai
                }
            }
            .onChange(of: session.agentModalActive) { _, active in
                if !active && !session.agentOpen { focusedAction = horizontalSizeClass == .compact ? .tools : .ai }
            }
            .onChange(of: horizontalSizeClass) { _, sizeClass in
                toolsExpanded = false
                if focusedAction != nil { focusedAction = sizeClass == .compact ? .tools : .ai }
            }
            .onChange(of: session.modelSettingsRequested) { _, requested in
                if requested {
                    session.modelSettingsRequested = false
                    presentModelSettings()
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .fileImporter(
            isPresented: $importing, allowedContentTypes: importingFolder ? [.folder] : markdownTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if importingFolder {
                    Task {
                        await session.grant(url)
                        session.reloadResources()
                    }
                } else {
                    Task { await session.open(url) }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { session.errorMessage = error.localizedDescription }
            }
        }
        .fileDialogDefaultDirectory(importingFolder ? session.resourcePermissionDirectory : nil)
        .sheet(
            isPresented: $modelSettingsPresented,
            onDismiss: {
                toolsExpanded = false
                focusedAction = horizontalSizeClass == .compact ? .tools : .more
                session.finishAgentConfiguration(saved: modelSettingsSaved)
                modelSettingsSaved = false
            }
        ) {
            ModelSettingsView(session: session) { modelSettingsSaved = true }
                .presentationBackgroundInteraction(.disabled)
                .interactiveDismissDisabled()
        }
        .alert(
            "无法完成操作",
            isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("好", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .alert("加载本地图片", isPresented: $session.needsResourcePermission) {
            Button("继续") {
                importingFolder = true
                importing = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("需要访问“\(session.resourcePermissionDirectory?.lastPathComponent ?? "")”文件夹。")
        }
        .alert("尚未配置模型", isPresented: $session.needsModelConfiguration) {
            Button("取消", role: .cancel) { session.finishAgentConfiguration(saved: false) }
            Button("前往设置") { session.modelSettingsRequested = true }
        }
        .alert("未能保存文档", isPresented: $session.closeSaveFailed) {
            Button("重试") { Task { await session.closeDocument() } }
                .keyboardShortcut(.defaultAction)
            Button("放弃修改并关闭", role: .destructive) {
                Task { await session.closeDocument(discardChanges: true) }
            }
            Button("取消", role: .cancel) { session.cancelDocumentClose() }
        } message: {
            Text("放弃修改将丢失未保存的内容。")
        }
    }

    private func welcome(viewport: CGSize) -> some View {
        let markSize = min(ReaderDesign.homeMark, max(ReaderDesign.homeMark / 2, viewport.height * 0.22))
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(HomeItem.allCases, id: \.self) { item in
                    let visible = reduceMotion || visibleHomeItems.contains(item)
                    homeContent(item, markSize: markSize)
                        .modifier(HomeEntrance(visible: visible, reduceMotion: reduceMotion))
                        .accessibilityHidden(item == .mark || !visible)
                        .padding(.top, item.spacingBefore)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 32)
            .frame(minHeight: viewport.height)
        }
        .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        .task(id: reduceMotion) { await revealHome() }
        .onDisappear {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { visibleHomeItems.removeAll() }
        }
    }

    @ViewBuilder
    private func homeContent(_ item: HomeItem, markSize: CGFloat) -> some View {
        switch item {
        case .mark:
            Image("BrandMark").renderingMode(.template).resizable().scaledToFit()
                .frame(width: markSize).foregroundStyle(.primary)
        case .slogan:
            ViewThatFits(in: .horizontal) {
                Text(homeSlogan.joined(separator: " ")).fixedSize()
                Text(homeSlogan.joined(separator: "\n"))
            }
            .font(.title2.weight(.medium)).foregroundStyle(.primary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(homeSlogan.joined(separator: " "))
            .accessibilityIdentifier("HomeSlogan")
        case .openDocument:
            Button("打开文档", systemImage: "doc", action: openDocument)
                .buttonStyle(.glassProminent).controlSize(.large)
                .accessibilityIdentifier("OpenDocument")
                .accessibilityFocused($focusedAction, equals: .open)
        case .recentDocuments:
            Button {
                recentsPresented = true
            } label: {
                Text("最近打开...")
                    .frame(minWidth: ReaderDesign.hitTarget, minHeight: ReaderDesign.hitTarget)
                    .contentShape(Rectangle())
            }
            .font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
            .accessibilityIdentifier("RecentDocuments")
            .accessibilityFocused($focusedAction, equals: .recents)
            .popover(isPresented: $recentsPresented, arrowEdge: .top) {
                RecentDocumentsView(
                    store: session.recentDocuments, compact: horizontalSizeClass == .compact,
                    open: { try await session.openRecent($0) }
                )
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.disabled)
            }
            .onChange(of: recentsPresented) { _, presented in
                if !presented && session.document == nil { focusedAction = .recents }
            }
        }
    }

    private func revealHome() async {
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { visibleHomeItems = Set(HomeItem.allCases) }
            return
        }
        guard visibleHomeItems.isEmpty else { return }
        await Task.yield()
        for (index, item) in HomeItem.allCases.enumerated() {
            if index > 0 {
                do { try await Task.sleep(for: .seconds(ReaderDesign.homeStagger)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: ReaderDesign.homeDuration)) { _ = visibleHomeItems.insert(item) }
        }
    }

    private var floatingActions: some View {
        let compact = horizontalSizeClass == .compact
        return GlassEffectContainer(spacing: ReaderDesign.floatingGap) {
            HStack(spacing: ReaderDesign.floatingGap) {
                if !compact || toolsExpanded {
                    HStack(spacing: ReaderDesign.floatingGap) {
                        if session.mode == "source" {
                            Button {
                                session.performSourceHistory("undo")
                            } label: {
                                actionIcon("arrow.uturn.backward", compact: compact)
                            }
                            .modifier(ReaderGlassControl())
                            .disabled(!session.canUndoSource)
                            .accessibilityLabel("撤销").accessibilityIdentifier("SourceUndo")
                            Button {
                                session.performSourceHistory("redo")
                            } label: {
                                actionIcon("arrow.uturn.forward", compact: compact)
                            }
                            .modifier(ReaderGlassControl())
                            .disabled(!session.canRedoSource)
                            .accessibilityLabel("重做").accessibilityIdentifier("SourceRedo")
                        }
                        Button {
                            session.toggleAgent()
                            toolsExpanded = false
                        } label: {
                            actionIcon("bubble.left", compact: compact)
                        }
                        .modifier(ReaderGlassControl())
                        .accessibilityLabel("AI").accessibilityIdentifier("GlobalAI")
                        .accessibilityFocused($focusedAction, equals: .ai)
                        .accessibilityHidden(compact && !toolsExpanded)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        Button {
                            session.toggleMode()
                            toolsExpanded = false
                        } label: {
                            actionIcon(
                                session.mode == "source" ? "book" : "chevron.left.forwardslash.chevron.right",
                                compact: compact)
                        }
                        .modifier(ReaderGlassControl())
                        .accessibilityLabel(session.mode == "source" ? "切换到预览" : "切换到源码")
                        .accessibilityIdentifier("ModeToggle")
                        .accessibilityHidden(compact && !toolsExpanded)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        Menu {
                            Button("模型设置", systemImage: "slider.horizontal.3") {
                                presentModelSettings()
                            }
                        } label: {
                            actionIcon("ellipsis", compact: compact)
                        }
                        .modifier(ReaderGlassControl())
                        .accessibilityLabel("更多").accessibilityIdentifier("More")
                        .accessibilityFocused($focusedAction, equals: .more)
                        .accessibilityHidden(compact && !toolsExpanded)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    .fixedSize()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if compact {
                    Button {
                        toolsExpanded.toggle()
                    } label: {
                        actionIcon("chevron.left", compact: true).rotationEffect(.degrees(toolsExpanded ? 180 : 0))
                    }
                    .modifier(ReaderGlassControl())
                    .accessibilityLabel(toolsExpanded ? "收起阅读工具" : "展开阅读工具")
                    .accessibilityIdentifier("ToolsToggle")
                    .accessibilityFocused($focusedAction, equals: .tools)
                }
            }
        }
        .foregroundStyle(.primary)
        .animation(reduceMotion ? nil : .easeOut(duration: ReaderDesign.toolsDuration), value: toolsExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: ReaderDesign.toolsDuration), value: session.mode)
    }

    private func presentModelSettings() {
        modelSettingsSaved = false
        let token = session.documentToken
        Task {
            await session.closeAgent()
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(280)) }
            guard session.document != nil, session.documentToken == token, !session.isClosingDocument else { return }
            modelSettingsPresented = true
        }
    }

    private func openDocument() {
        importingFolder = false
        importing = true
    }

    private func actionIcon(_ symbol: String, compact: Bool) -> some View {
        Image(systemName: symbol).font(
            .system(size: compact ? ReaderDesign.compactFloatingIcon : ReaderDesign.floatingIcon)
        )
        .frame(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget).contentShape(Circle())
    }

}

private struct HomeEntrance: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -ReaderDesign.homeEntranceOffset)
            .allowsHitTesting(visible)
            .transaction {
                if reduceMotion {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            }
    }
}

/// All floating reader controls use the same system material and circular feedback.
private struct ReaderGlassControl: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
    }
}
