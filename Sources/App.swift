import SwiftUI

@main
struct SalhaScanApp: App {
    var body: some Scene {
        WindowGroup {
            WebHost()
                .ignoresSafeArea()
        }
    }
}

struct WebHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ vc: WebViewController, context: Context) {}
}
