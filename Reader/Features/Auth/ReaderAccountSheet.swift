import SwiftUI

struct ReaderAccountSheet: View {
    @Bindable var account: ReaderAccountModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReaderAuthenticationView(account: account)
            .frame(width: 760, height: 560)
        .onChange(of: account.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { dismiss() }
        }
    }
}
