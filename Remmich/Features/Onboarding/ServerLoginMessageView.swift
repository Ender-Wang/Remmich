import SwiftUI

struct ServerLoginMessageView: View {
    let html: String
    let baseURL: URL

    var body: some View {
        Text(attributedMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributedMessage: AttributedString {
        var result = AttributedString()
        for segment in ServerLoginMessage(html: html, baseURL: baseURL).segments {
            var text = AttributedString(segment.text)
            var intent: InlinePresentationIntent = []
            if segment.style.bold {
                intent.insert(.stronglyEmphasized)
            }
            if segment.style.italic {
                intent.insert(.emphasized)
            }
            text.inlinePresentationIntent = intent
            if segment.style.warning {
                text.foregroundColor = .red
            }
            text.link = segment.style.link
            result.append(text)
        }
        return result
    }
}
