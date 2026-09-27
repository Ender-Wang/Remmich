import SwiftUI

extension FixturePalette {
    var colors: [Color] {
        switch self {
        case .coast: [.cyan, .blue]
        case .forest: [.mint, .green]
        case .sunset: [.orange, .pink]
        case .lavender: [.purple, .indigo]
        case .glacier: [.white, .cyan]
        case .city: [.gray, .indigo]
        case .citrus: [.yellow, .orange]
        case .night: [.indigo, .black]
        }
    }
}

struct FixtureArtwork: View {
    let palette: FixturePalette
    var systemImage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: 90, height: 90)
                .offset(x: 36, y: -34)

            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            }
        }
        .clipped()
    }
}
