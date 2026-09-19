import Observation
import SwiftUI

enum QuietToastKind: String, CaseIterable, Sendable {
    case done
    case wait
    case stop
    case note

    var dotColor: Color {
        switch self {
        case .done:
            Color(
                red: 63.0 / 255.0,
                green: 143.0 / 255.0,
                blue: 95.0 / 255.0
            )
        case .wait:
            Color(
                red: 192.0 / 255.0,
                green: 139.0 / 255.0,
                blue: 43.0 / 255.0
            )
        case .stop:
            Color(
                red: 180.0 / 255.0,
                green: 68.0 / 255.0,
                blue: 58.0 / 255.0
            )
        case .note:
            QuietReaderColor.ink
        }
    }
}

struct QuietToastItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String
    let kind: QuietToastKind

    init(
        id: UUID = UUID(),
        message: String,
        kind: QuietToastKind
    ) {
        self.id = id
        self.message = message
        self.kind = kind
    }
}

@MainActor
@Observable
final class QuietToastCenter {
    private(set) var current: QuietToastItem?
    private var dismissalTask: Task<Void, Never>?

    func show(_ message: String, kind: QuietToastKind) {
        dismissalTask?.cancel()
        let item = QuietToastItem(
            message: message.lowercased().trimmingCharacters(in: .punctuationCharacters),
            kind: kind
        )
        current = item
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, self?.current?.id == item.id else {
                return
            }
            self?.current = nil
        }
    }
}

struct QuietToastOverlay: View {
    @Bindable var center: QuietToastCenter

    var body: some View {
        VStack {
            Spacer()

            if let toast = center.current {
                QuietToastView(toast: toast)
                    .id(toast.id)
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: 10).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(.bottom, 38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(QuietReaderMotion.toast, value: center.current?.id)
        .accessibilityElement(children: .contain)
    }
}

private struct QuietToastView: View {
    let toast: QuietToastItem

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(toast.kind.dotColor)
                .frame(width: 6, height: 6)

            Text(toast.message)
                .font(QuietReaderTypography.appVoice(size: 13))
                .tracking(QuietReaderTypography.tracking(for: 13))
                .foregroundStyle(QuietReaderColor.ink)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(QuietReaderColor.paper, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.black.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 17, y: 14)
        .accessibilityLabel(toast.message)
    }
}
