import SwiftUI

struct TipJarView: View {
    let store: TipStore
    var body: some View {
        List {
            Section {
                Text("The app is free. No account, no subscription, no telemetry. If it helps you, you can leave a tip. Tips unlock nothing.")
                    .accessibilityIdentifier("tips.disclosure")
            }
            Section("Leave a tip") {
                ForEach(store.products) { product in
                    Button {
                        Task { await store.tip(productID: product.id) }
                    } label: {
                        HStack { Text(verbatim: product.displayName); Spacer(); Text(verbatim: product.displayPrice) }
                    }.disabled(store.state == .purchasing || store.state == .loading || store.state == .pending)
                        .accessibilityIdentifier("tips.product.\(product.id)")
                }
                switch store.state {
                case .loading: ProgressView("Loading tips…")
                case .purchasing: ProgressView("Completing your tip…")
                case .pending:
                    Text("Your tip is awaiting approval. You can keep training while it is pending.").accessibilityIdentifier("tips.pending")
                case .thankYou:
                    Text("Thank you for helping keep Plenty Strong free.").accessibilityIdentifier("tips.thank-you")
                case .failed:
                    Text(store.message ?? String(localized: "Tips are unavailable right now. All training features and backups are free.")).accessibilityIdentifier("tips.failure")
                    Button("Try again") { Task { await store.load() } }.accessibilityIdentifier("tips.retry")
                case .idle, .ready: EmptyView()
                }
            }
        }.navigationTitle("Optional tips").task { await store.load() }
    }
}
