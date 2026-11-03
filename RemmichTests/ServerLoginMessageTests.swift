import Foundation
import Testing
@testable import Remmich

struct ServerLoginMessageTests {
    private let baseURL = URL(string: "https://server.example/immich/")!

    @Test func rendersFormattingAndEntitiesWithoutShowingMarkup() {
        let message = ServerLoginMessage(
            html: "  Demo &amp; test.<br><b style='color: red'>Uploads disabled.</b><p><em>Reset &#10003; &#x1F4F7;</em></p>",
            baseURL: baseURL
        )
        #expect(message.plainText == "Demo & test.\nUploads disabled.\nReset ✓ 📷")
        #expect(message.segments.contains { $0.text == "Uploads disabled." && $0.style.bold && $0.style.warning })
        #expect(message.segments.contains { $0.text.contains("Reset") && $0.style.italic })
        #expect(ServerLoginMessage(html: "First<br><br>Second", baseURL: baseURL).plainText == "First\n\nSecond")
    }

    @Test func demoJavaScriptLinkRemainsInertText() {
        let message = ServerLoginMessage(
            html: #"Demo.<br><a href="javascript: email.value = 'example'; password.value = 'test'; document.forms[0].requestSubmit();">Login as demo user</a>"#,
            baseURL: baseURL
        )
        #expect(message.plainText == "Demo.\nLogin as demo user")
        #expect(message.segments.allSatisfy { $0.style.link == nil })
        #expect(!message.plainText.contains("password.value"))
    }

    @Test func resolvesOrdinaryLinksAndRejectsExecutableSchemes() {
        let message = ServerLoginMessage(
            html: #"<a href="help?x=1&amp;y=2">Help</a> <a href="data:text/html,test">Data</a> <a href="java&#115;cript:alert(1)">Script</a>"#,
            baseURL: baseURL
        )
        #expect(message.segments.first?.style.link?.absoluteString == "https://server.example/immich/help?x=1&y=2")
        #expect(message.segments.filter { $0.style.link != nil }.count == 1)
        #expect(message.plainText == "Help Data Script")
    }

    @Test func ignoresActiveContentAndKeepsNestedFormattingBounded() {
        let message = ServerLoginMessage(
            html: #"<script>fetch('https://bad.example')</script><style>body { color:red }</style><!-- hidden --><b>Bold <i>both</i> bold</b> normal<img src="https://bad.example/image"><a href="javascript: if (2 > 1) alert(1)">Inert</a>"#,
            baseURL: baseURL
        )
        #expect(message.plainText == "Bold both bold normalInert")
        #expect(message.segments.first?.style.bold == true)
        #expect(message.segments.contains { $0.text == "both" && $0.style.bold && $0.style.italic })
        #expect(message.segments.last?.style == .init())
    }
}
