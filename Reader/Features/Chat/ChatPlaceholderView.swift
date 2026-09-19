import SwiftUI

struct ChatPlaceholderView: View {
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "message")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Chat")
                    .font(.system(size: 24, weight: .semibold))

                Text("Your reading companion will live here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                TextField("Ask about what you’re reading", text: $draft)
                    .textFieldStyle(.plain)
                    .disabled(true)

                Button { } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(ReaderColors.ink, in: Circle())
                        .foregroundStyle(ReaderColors.paper)
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                ReaderColors.paper,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ReaderColors.hairline)
            }
            .padding(16)
        }
        .background(ReaderColors.canvas)
    }
}
