import SwiftUI

struct FixtureAssetDetailView: View {
    let asset: FixtureAsset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FixtureArtwork(palette: asset.palette, systemImage: asset.kind.systemImage)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 22))

                VStack(alignment: .leading, spacing: 8) {
                    Text(asset.title)
                        .font(.title2.bold())
                    Label(asset.location, systemImage: "location")
                    Label(asset.capturedAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    Label("Immich library · Read only", systemImage: "lock")
                }
                .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(asset.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
