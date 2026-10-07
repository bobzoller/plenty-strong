import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section("Plenty Strong") { Text("Private training with a fixed routine and a replayable local record.") }
            Section("Privacy · October 6, 2026") {
                Text("No account, no subscription, no telemetry. Workout records, setup descriptions and decisions are stored in the app's local store. There is no analytics or crash-reporting SDK. Sharing a JSON backup sends its training data to the destination you choose. Your operating system may also back up app files under your Apple settings.").accessibilityIdentifier("about.privacy")
                Text("Optional iCloud recovery uses your private Apple CloudKit database after consent and reviewed provisioning. This candidate keeps its provisioning gate off. Optional tips use Apple StoreKit and grant no features. Apple processes these services; local training never requires them.")
            }
            Section("Export and optional services") {
                Text("Training JSON backups exclude account, cloud-engine and commerce metadata. A separate local tip cache stores verified transaction/product identifiers and completion status; it is never training history. Turning recovery off stops syncing but does not delete existing iCloud records. No app web or support link is published yet.")
            }
            Section("Source and attribution") {
                Text("Public source publication and a verified source link are pending release review. No remote repository is represented as published.")
                Text("Kado by Sébastien Castiel inspired the native, local-first approach. This candidate incorporates no Kado source or assets. Apple frameworks are supplied under Apple’s terms.")
                Text("License: MIT. Copyright © 2026 Plenty Strong contributors.")
                Text(Self.mit).font(.caption).textSelection(.enabled).accessibilityIdentifier("about.license")
            }
        }.navigationTitle("About and privacy")
    }
    private static let mit = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
