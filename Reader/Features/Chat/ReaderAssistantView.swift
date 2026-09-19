import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ReaderAssistantView: View {
    @Bindable var session: ReaderAssistantSession
    @Bindable var account: ReaderAccountModel
    let loadBookKnowledge: (() -> ReaderBookKnowledgeSnapshot?)?

    @State private var showAccount = false
    @State private var showAttachmentPicker = false
    @State private var showContextChooser = false
    @State private var showSelectionPreview = false
    @State private var scopeIsHovered = false
    @State private var previewIsHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: ReaderAssistantSession,
        account: ReaderAccountModel,
        loadBookKnowledge: (() -> ReaderBookKnowledgeSnapshot?)? = nil
    ) {
        self.session = session
        self.account = account
        self.loadBookKnowledge = loadBookKnowledge
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title = session.displayTitle {
                conversationHeader(title)
            }
            transcript
            composer
        }
        .background(QuietReaderColor.paper)
        .sheet(isPresented: $showAccount) {
            ReaderAccountSheet(account: account)
        }
        .fileImporter(
            isPresented: $showAttachmentPicker,
            allowedContentTypes: [.image, .pdf, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                session.addAttachments(from: urls)
            }
        }
        .onChange(of: account.isAuthenticated) { _, isAuthenticated in
            guard isAuthenticated else { return }
            Task { @MainActor in
                await session.prepareBookKnowledge(using: account)
                if session.canSend {
                    session.send(using: account)
                }
            }
        }
        .onChange(of: session.isPassageAttached) { _, isAttached in
            if !isAttached {
                showSelectionPreview = false
            }
        }
        .task {
            guard let snapshot = loadBookKnowledge?() else { return }
            session.attachBookKnowledge(snapshot)
            if account.isAuthenticated {
                await session.prepareBookKnowledge(using: account)
            }
        }
    }

    private func conversationHeader(_ title: String) -> some View {
        HStack(spacing: 12) {
            QuietContentText(
                text: title,
                size: 13,
                weight: .medium,
                color: QuietReaderColor.ink
            )
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 54)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 27) {
                    if session.messages.isEmpty {
                        Color.clear
                            .frame(height: 1)
                    }

                    ForEach(session.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }

                    if let error = session.errorMessage {
                        QuietVoiceText(
                            text: error,
                            size: 12,
                            color: QuietReaderColor.voice
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.messages.last?.text) { _, _ in
                guard let last = session.messages.last else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: session.messages.count) { _, _ in
                guard let last = session.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: ReaderAssistantMessage) -> some View {
        switch message.role {
        case .reader:
            VStack(alignment: .trailing, spacing: 14) {
                if let passage = message.passage {
                    passageQuote(passage, compact: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if !message.attachments.isEmpty {
                    attachmentList(message.attachments, removable: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Text(message.text)
                    .font(QuietReaderTypography.content(size: 14))
                    .tracking(QuietReaderTypography.tracking(for: 14))
                    .foregroundStyle(QuietReaderColor.ink)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        Color.black.opacity(0.055),
                        in: RoundedRectangle(
                            cornerRadius: 17,
                            style: .continuous
                        )
                    )
                    .frame(maxWidth: 310, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if isWaitingForFirstToken(message) {
                    ReaderAssistantLoadingBubble()
                } else {
                    Text(message.displayText)
                        .font(QuietReaderTypography.content(size: 15))
                        .tracking(QuietReaderTypography.tracking(for: 15))
                        .foregroundStyle(QuietReaderColor.ink)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: 330, alignment: .leading)
                }

                if let evidence = message.evidenceLabel {
                    QuietVoiceText(
                        text: evidence,
                        size: 10,
                        color: QuietReaderColor.voice
                    )
                }
            }
        }
    }

    private var scopeMenu: some View {
        let scope = session.effectiveContextScope

        return Menu {
            ForEach(ReaderContextScope.userSelectableScopes, id: \.self) { choice in
                Button {
                    session.setContextScope(choice)
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(choice.title)
                            Text(scopeDetail(for: choice))
                        }
                    } icon: {
                        ReaderContextGlyph(
                            scope: choice,
                            pageNumber: session.currentPageNumber
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                ReaderContextScopeIcon(
                    scope: scope,
                    pageNumber: session.currentPageNumber
                )

                VStack(alignment: .leading, spacing: 1) {
                    QuietContentText(
                        text: scope.title,
                        size: 11,
                        weight: .medium,
                        color: QuietReaderColor.ink
                    )
                    QuietVoiceText(
                        text: composerScopeDetail,
                        size: 9,
                        color: QuietReaderColor.voice
                    )
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(QuietReaderColor.voice)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                scopeIsHovered ? QuietUtilityControl.hoverBackground : .clear,
                in: RoundedRectangle(
                    cornerRadius: QuietUtilityControl.cornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : QuietReaderMotion.workspaceTab,
                value: scope
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.isAnswering)
        .onHover { scopeIsHovered = $0 }
        .accessibilityLabel("Book context: \(scope.title)")
        .accessibilityHint(scope.detail)
    }

    private var selectionPreviewButton: some View {
        Button {
            showSelectionPreview.toggle()
        } label: {
            Image("ReaderContextReveal")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    showSelectionPreview
                        ? QuietUtilityControl.activeInk
                        : QuietUtilityControl.restingInk
                )
                .frame(
                    width: QuietUtilityControl.symbolSize,
                    height: QuietUtilityControl.symbolSize
                )
                .frame(
                    width: QuietUtilityControl.size,
                    height: QuietUtilityControl.size
                )
                .background(
                    selectionPreviewButtonBackground,
                    in: RoundedRectangle(
                        cornerRadius: QuietUtilityControl.cornerRadius,
                        style: .continuous
                    )
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: QuietUtilityControl.cornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .onHover { previewIsHovered = $0 }
        .popover(
            isPresented: $showSelectionPreview,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            selectionPreview
                .presentationBackground(QuietReaderColor.paper)
        }
        .help("Show selected text")
        .accessibilityLabel("Show selected text")
        .accessibilityValue(showSelectionPreview ? "Shown" : "Hidden")
        .accessibilityAddTraits(showSelectionPreview ? .isSelected : [])
    }

    private var selectionPreviewButtonBackground: Color {
        if showSelectionPreview && previewIsHovered {
            return QuietUtilityControl.selectedHoverBackground
        }
        if showSelectionPreview { return QuietUtilityControl.selectedBackground }
        if previewIsHovered { return QuietUtilityControl.hoverBackground }
        return .clear
    }

    @ViewBuilder
    private var selectionPreview: some View {
        if let passage = session.passageQuote {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    QuietContentText(
                        text: "selection",
                        size: 12,
                        weight: .medium,
                        color: QuietReaderColor.ink
                    )
                    Spacer()
                    Button {
                        showSelectionPreview = false
                        session.detachPassage()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(QuietReaderColor.voice)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Remove selection")
                    .accessibilityLabel("Remove selection")
                }

                ScrollView {
                    Text(passage.text)
                        .font(QuietReaderTypography.reading(size: 14, serif: true))
                        .foregroundStyle(QuietReaderColor.inkSecondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)

                QuietVoiceText(
                    text: passage.source,
                    size: 10,
                    color: QuietReaderColor.voice
                )
            }
            .padding(16)
            .frame(width: 330, height: 240)
            .background(QuietReaderColor.paper)
        }
    }

    private var composerScopeDetail: String {
        switch session.processingStatus {
        case .preparing:
            "preparing this book"
        case .failed:
            "book search unavailable"
        case .notStarted, .parsed:
            if
                session.effectiveContextScope == .upToHere,
                let pageNumber = session.currentPageNumber
            {
                "through page \(pageNumber) · no spoilers"
            } else {
                session.effectiveContextScope.detail
            }
        }
    }

    private func scopeDetail(for scope: ReaderContextScope) -> String {
        if scope == .upToHere, let pageNumber = session.currentPageNumber {
            return "through page \(pageNumber) · no spoilers"
        }
        return scope.detail
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                scopeMenu

                if session.isPassageAttached {
                    selectionPreviewButton
                        .transition(
                            reduceMotion
                                ? .identity
                                : .opacity.combined(with: .scale(scale: 0.94))
                        )
                }
            }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 7)
                .animation(
                    reduceMotion ? nil : QuietReaderMotion.workspaceTab,
                    value: session.isPassageAttached
                )

            if !session.pendingAttachments.isEmpty {
                attachmentList(session.pendingAttachments, removable: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            HStack(alignment: .center, spacing: 10) {
                Button {
                    showContextChooser.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(QuietReaderColor.ink.opacity(0.72))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(session.isAnswering)
                .popover(
                    isPresented: $showContextChooser,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    contextChooser
                        .presentationBackground(QuietReaderColor.paper)
                }
                .help("Attach an image or document")
                .accessibilityLabel("Add context")

                TextField(
                    "message",
                    text: $session.draftQuestion,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(QuietReaderTypography.content(size: 14))
                .foregroundStyle(QuietReaderColor.ink)
                .lineLimit(1...5)
                .frame(minHeight: 34, alignment: .center)
                .onSubmit(send)

                Button(action: primaryComposerAction) {
                    ZStack {
                        Circle()
                            .fill(QuietReaderColor.ink)

                        Image(
                            systemName: session.isAnswering
                                ? "stop.fill"
                                : "arrow.up"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QuietReaderColor.paper)
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!session.isAnswering && !session.canSend)
                .accessibilityLabel(
                    session.isAnswering ? "Stop response" : "Send message"
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .background(
            QuietReaderColor.paper,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.055), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var contextChooser: some View {
        VStack(spacing: 2) {
            ReaderContextChoice(
                title: "image or document",
                detail: "photo, pdf or text file",
                systemImage: "paperclip"
            ) {
                showContextChooser = false
                Task { @MainActor in
                    await Task.yield()
                    showAttachmentPicker = true
                }
            }
        }
        .padding(6)
        .frame(width: 218)
        .background(QuietReaderColor.paper)
    }

    private func passageQuote(
        _ passage: ReaderPassageQuote,
        compact: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: compact ? 10 : 12) {
            Image(systemName: "quote.opening")
                .font(.system(size: compact ? 11 : 13, weight: .medium))
                .foregroundStyle(QuietReaderColor.voice)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: compact ? 7 : 8) {
                Text(passage.text)
                    .font(
                        QuietReaderTypography.reading(
                            size: compact ? 13 : 14,
                            serif: true
                        )
                    )
                    .foregroundStyle(QuietReaderColor.inkSecondary.opacity(0.88))
                    .lineSpacing(compact ? 3 : 4)
                    .lineLimit(compact ? 2 : 5)

                Text(passage.source)
                    .font(QuietReaderTypography.appVoice(size: 11))
                    .tracking(QuietReaderTypography.tracking(for: 11))
                    .foregroundStyle(QuietReaderColor.voice)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: compact ? .infinity : 280, alignment: .leading)
    }

    private func attachmentList(
        _ attachments: [ReaderChatAttachment],
        removable: Bool
    ) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 7) {
                    Image(systemName: attachment.systemImage)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(QuietReaderColor.voice)

                    Text(attachment.filename)
                        .font(QuietReaderTypography.content(size: 11))
                        .foregroundStyle(QuietReaderColor.inkSecondary)
                        .lineLimit(1)

                    if removable {
                        Button {
                            session.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(QuietReaderColor.voice)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.filename)")
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, removable ? 5 : 10)
                .frame(height: 30)
                .background(
                    Color.black.opacity(0.045),
                    in: Capsule()
                )
            }
        }
    }

    private func isStreaming(_ message: ReaderAssistantMessage) -> Bool {
        session.isAnswering
            && message.role == .assistant
            && session.messages.last?.id == message.id
    }

    private func isWaitingForFirstToken(
        _ message: ReaderAssistantMessage
    ) -> Bool {
        isStreaming(message) && message.text.isEmpty
    }

    private func primaryComposerAction() {
        if session.isAnswering {
            session.stopAnswering()
        } else {
            send()
        }
    }

    private func send() {
        guard session.canSend else { return }
        if account.isAuthenticated {
            session.send(using: account)
        } else {
            showAccount = true
        }
    }
}

private struct ReaderContextScopeIcon: View {
    let scope: ReaderContextScope
    let pageNumber: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ReaderContextGlyph(scope: scope, pageNumber: pageNumber)
                .foregroundStyle(QuietUtilityControl.activeInk)
                .frame(
                    width: QuietUtilityControl.symbolSize,
                    height: QuietUtilityControl.symbolSize
                )
                .id(scope)
                .transition(iconTransition)
        }
        .frame(
            width: QuietUtilityControl.size,
            height: QuietUtilityControl.size
        )
        .background(
            QuietUtilityControl.selectedBackground,
            in: RoundedRectangle(
                cornerRadius: QuietUtilityControl.cornerRadius,
                style: .continuous
            )
        )
        .animation(
            reduceMotion ? nil : QuietReaderMotion.workspaceTab,
            value: scope
        )
    }

    private var iconTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.84)),
            removal: .opacity.combined(with: .scale(scale: 0.92))
        )
    }
}

private struct ReaderContextGlyph: View {
    let scope: ReaderContextScope
    let pageNumber: Int?

    var body: some View {
        image
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: QuietUtilityControl.symbolSize,
                height: QuietUtilityControl.symbolSize
            )
            .accessibilityHidden(true)
    }

    private var image: Image {
#if os(macOS)
        if scope == .upToHere {
            return Image(
                nsImage: ReaderContextGlyphImage.upToHere(pageNumber: pageNumber)
            )
        }
#endif
        return Image(scope.assetName)
    }
}

#if os(macOS)
@MainActor
enum ReaderContextPageNumberLayout {
    static func value(for pageNumber: Int) -> NSString {
        String(pageNumber) as NSString
    }

    static func fontSize(forDigitCount digitCount: Int) -> CGFloat {
        switch digitCount {
        case ...2: 5
        case 3: 4.6
        default: 3.8
        }
    }
}

@MainActor
private enum ReaderContextGlyphImage {
    static func upToHere(pageNumber: Int?) -> NSImage {
        // Use the asset for both the menu and the composer. A second hand-drawn
        // outline used to drift from the SVG whenever the icon was refined.
        let outline = NSImage(named: "ReaderContextUpToHere")
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            outline?.draw(
                in: NSRect(x: 0, y: 0, width: 20, height: 20),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )

            if let pageNumber {
                let value = ReaderContextPageNumberLayout.value(for: pageNumber)
                let digitCount = value.length
                let fontSize = ReaderContextPageNumberLayout.fontSize(
                    forDigitCount: digitCount
                )
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: fontSize,
                        weight: .medium
                    ),
                    .foregroundColor: NSColor.black
                ]
                let textSize = value.size(withAttributes: attributes)
                value.draw(
                    at: NSPoint(
                        x: 16.2 - textSize.width,
                        y: 16.1 - textSize.height
                    ),
                    withAttributes: attributes
                )
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
#endif

struct ReaderAssistantLoadingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var phaseOverride: TimeInterval?

    init(phaseOverride: TimeInterval? = nil) {
        self.phaseOverride = phaseOverride
    }

    @ViewBuilder
    var body: some View {
        if let phaseOverride {
            bubble(phase: phaseOverride)
        } else if reduceMotion {
            bubble(phase: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                bubble(
                    phase: context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1)
                )
            }
        }
    }

    private func bubble(phase: TimeInterval) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(QuietReaderColor.ink.opacity(0.62))
                    .frame(width: 4, height: 4)
                    .offset(
                        y: Self.verticalOffset(
                            for: index,
                            phase: phase
                        )
                    )
            }
        }
            .frame(width: 32, height: 32)
            .background(QuietReaderColor.paper, in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Waiting for response")
            .accessibilityIdentifier("reader-assistant-loading")
    }

    static func verticalOffset(
        for dot: Int,
        phase: TimeInterval
    ) -> CGFloat {
        let localPhase = phase - (Double(dot) * 0.10)
        guard localPhase >= 0, localPhase <= motionSamples.last!.time else {
            return 0
        }

        for index in 0..<(motionSamples.count - 1) {
            let start = motionSamples[index]
            let end = motionSamples[index + 1]
            guard localPhase <= end.time else { continue }
            let progress = (localPhase - start.time) / (end.time - start.time)
            return start.offset
                + ((end.offset - start.offset) * CGFloat(progress))
        }

        return 0
    }

    private static let motionSamples: [
        (time: TimeInterval, offset: CGFloat)
    ] = [
        (0.00, 0.0),
        (0.05, 0.0),
        (0.10, 0.6),
        (0.15, 2.0),
        (0.20, 2.5),
        (0.25, 2.1),
        (0.30, 1.1),
        (0.35, -0.5),
        (0.40, -2.1),
        (0.45, -3.5),
        (0.50, -4.0),
        (0.55, -3.5),
        (0.60, -1.0),
        (0.65, 0.0),
    ]
}

private struct ReaderContextChoice: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(QuietReaderColor.voice)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(QuietReaderTypography.content(size: 13))
                        .tracking(QuietReaderTypography.tracking(for: 13))
                        .foregroundStyle(QuietReaderColor.ink)

                    Text(detail)
                        .font(QuietReaderTypography.appVoice(size: 11))
                        .tracking(QuietReaderTypography.tracking(for: 11))
                        .foregroundStyle(QuietReaderColor.voice)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .contentShape(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .background(
                isHovered ? Color.black.opacity(0.045) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
