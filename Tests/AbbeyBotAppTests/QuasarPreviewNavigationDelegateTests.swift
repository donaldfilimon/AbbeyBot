import Foundation
import Testing
import WebKit
@testable import AbbeyBotApp

@MainActor struct QuasarPreviewNavigationDelegateTests {
    @Test func delegateRegistersWebKitPolicyCallbackAndRejectsCrossOriginNavigation() {
        let delegate = QuasarPreviewNavigationDelegate(
            origin: URL(string: "https://site.preview.example.test")!
        )
        let selector = NSSelectorFromString(
            "webView:decidePolicyForNavigationAction:decisionHandler:"
        )

        #expect(delegate.responds(to: selector))
        #expect(
            delegate.policy(for: URL(string: "https://outside.example.test")) == .cancel
        )
        #expect(
            delegate.policy(for: URL(string: "https://site.preview.example.test/page")) == .allow
        )
    }
}
