#if DEBUG
import SwiftUI

struct QuietReaderFoundationPreview: View {
    @State private var selection = QuietReaderMenuItem.everything
    @State private var markIndex = 0
    @State private var toastCenter = QuietToastCenter()
    @State private var toastIndex = 0

    private let toastSamples: [(String, QuietToastKind)] = [
        ("kept", .done),
        ("google sign-in isn't ready yet", .wait),
        ("couldn't open that file", .stop),
        ("we'll send you a link", .note),
    ]

    var body: some View {
        ZStack {
            QuietReaderColor.paper
                .ignoresSafeArea()

            QuietReaderMenuColumn(
                selection: selection,
                mark: currentMark,
                select: select,
                openAccount: showNextToast
            )

            VStack(spacing: 22) {
                QuietVoiceText(
                    text: "your mark",
                    size: 13,
                    color: QuietReaderColor.voiceQuiet
                )

                Button(action: showNextToast) {
                    QuietAccountMarkView(mark: currentMark, size: 96)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("preview toast")

                QuietActionWord(
                    title: "draw another",
                    size: 13
                ) {
                    markIndex = (markIndex + 1) % QuietAccountMark.allCases.count
                    showNextToast()
                }

                QuietVoiceText(
                    text: "drawn from your name — no photograph, no upload.",
                    size: 12,
                    color: Color(
                        red: 192.0 / 255.0,
                        green: 192.0 / 255.0,
                        blue: 194.0 / 255.0
                    )
                )
                .frame(maxWidth: 180)
                .multilineTextAlignment(.center)
                .lineSpacing(7.2)
            }

            QuietToastOverlay(center: toastCenter)
        }
        .onAppear {
            toastCenter.show("kept", kind: .done)
        }
    }

    private var currentMark: QuietAccountMark {
        QuietAccountMark.allCases[markIndex]
    }

    private func select(_ item: QuietReaderMenuItem) {
        withAnimation(QuietReaderMotion.screen) {
            selection = item
        }
    }

    private func showNextToast() {
        let sample = toastSamples[toastIndex]
        toastIndex = (toastIndex + 1) % toastSamples.count
        toastCenter.show(sample.0, kind: sample.1)
    }
}
#endif
