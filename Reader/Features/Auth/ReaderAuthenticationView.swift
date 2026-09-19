import SwiftUI

enum ReaderAuthenticationMode: String, CaseIterable, Identifiable {
    case createAccount
    case signIn

    var id: String { rawValue }
}

struct ReaderAuthenticationView: View {
    @Bindable var account: ReaderAccountModel

    @State private var mode = ReaderAuthenticationMode.signIn
    @State private var toast = QuietToastCenter()

    var body: some View {
        ZStack {
            QuietReaderColor.paper.ignoresSafeArea()

            if mode == .signIn {
                QuietSignInView(account: account, mode: $mode, toast: toast)
                    .transition(.opacity)
            } else {
                QuietCreateAccountView(account: account, mode: $mode, toast: toast)
                    .transition(.opacity)
            }

            QuietToastOverlay(center: toast)
        }
        .animation(QuietReaderMotion.screen, value: mode)
    }
}

private struct QuietSignInView: View {
    @Bindable var account: ReaderAccountModel
    @Binding var mode: ReaderAuthenticationMode
    @Bindable var toast: QuietToastCenter

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            QuietVoiceText(text: "welcome back.", size: 15, color: QuietReaderColor.voice)
            VStack(spacing: 26) {
                QuietCredentialField("email", text: $email)
                QuietCredentialField("password", text: $password, secure: true)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    QuietActionWord(title: "go in", size: 15, restingColor: QuietReaderColor.ink) {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)

                    Spacer()

                    Button {
                        toast.show("we'll send you a link", kind: .note)
                    } label: {
                        QuietVoiceText(text: "forgot it", color: QuietReaderColor.voiceFaint)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    account.clearFeedback()
                    mode = .createAccount
                } label: {
                    QuietVoiceText(text: "create an account")
                }
                .buttonStyle(.plain)
            }

            feedback
        }
        .frame(width: 340)
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = account.errorMessage {
            QuietVoiceText(text: error, color: QuietToastKind.stop.dotColor)
                .fixedSize(horizontal: false, vertical: true)
        } else if account.isAuthenticating {
            QuietVoiceText(text: "going in", color: QuietReaderColor.voice)
        }
    }

    private func submit() {
        guard email.contains("@"), password.count >= 8, !account.isAuthenticating else {
            toast.show("email and eight characters please", kind: .stop)
            return
        }
        Task { await account.signIn(email: email, password: password) }
    }
}

private struct QuietCreateAccountView: View {
    @Bindable var account: ReaderAccountModel
    @Binding var mode: ReaderAuthenticationMode
    @Bindable var toast: QuietToastCenter

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var markVariation = 0

    private var mark: QuietAccountMark {
        QuietAccountMark.deterministic(for: "\(name)-\(markVariation)")
    }

    var body: some View {
        HStack(spacing: 96) {
            VStack(alignment: .leading, spacing: 40) {
                QuietVoiceText(
                    text: "a shelf of your own.",
                    size: 15,
                    color: QuietReaderColor.voice
                )
                VStack(spacing: 26) {
                    QuietCredentialField("name", text: $name)
                    QuietCredentialField("email", text: $email)
                    QuietCredentialField("password", text: $password, secure: true)
                }

                HStack(spacing: 24) {
                    QuietActionWord(
                        title: "begin",
                        size: 15,
                        restingColor: QuietReaderColor.ink
                    ) { submit() }
                    .keyboardShortcut(.defaultAction)

                    Button {
                        account.clearFeedback()
                        mode = .signIn
                    } label: {
                        QuietVoiceText(text: "i already have one")
                    }
                    .buttonStyle(.plain)
                }

                feedback
            }
            .frame(width: 340)

            VStack(spacing: 17) {
                QuietVoiceText(text: "your mark")
                QuietAccountMarkView(mark: mark, size: 96)
                QuietActionWord(title: "draw another") {
                    markVariation += 1
                }
                QuietVoiceText(
                    text: "drawn from your name — no photograph, no upload.",
                    size: 12,
                    color: Color(red: 192 / 255, green: 192 / 255, blue: 194 / 255)
                )
            }
            .frame(width: 250)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = account.errorMessage {
            QuietVoiceText(text: error, color: QuietToastKind.stop.dotColor)
                .fixedSize(horizontal: false, vertical: true)
        } else if let notice = account.noticeMessage {
            QuietVoiceText(text: notice, color: QuietReaderColor.voice)
                .fixedSize(horizontal: false, vertical: true)
        } else if account.isAuthenticating {
            QuietVoiceText(text: "making your shelf", color: QuietReaderColor.voice)
        }
    }

    private func submit() {
        guard
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            email.contains("@"),
            password.count >= 8,
            !account.isAuthenticating
        else {
            toast.show("name email and eight characters please", kind: .stop)
            return
        }
        Task {
            await account.signUp(name: name, email: email, password: password)
        }
    }
}

private struct QuietCredentialField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, secure: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.secure = secure
    }

    var body: some View {
        VStack(spacing: 9) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                        .textContentType(.password)
                } else {
                    TextField(placeholder, text: $text)
                        .textContentType(placeholder == "email" ? .emailAddress : .name)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 19, weight: .light))
            .foregroundStyle(QuietReaderColor.ink)
            .focused($focused)
            .frame(width: 340, alignment: .leading)

            Rectangle()
                .fill(
                    focused
                        ? QuietReaderColor.ink
                        : Color(red: 228 / 255, green: 228 / 255, blue: 230 / 255)
                )
                .frame(width: 340, height: 1)
        }
        .frame(width: 340)
    }
}
