import SwiftUI

struct MapsPlacesSettingsView: View {
    @Environment(\.assetLocations) private var locations
    @State private var endpoint = MapsPlacesPreferences.defaultEndpoint
    @State private var message: String?
    @State private var isTesting = false
    @State private var showsCountries = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Place-name Service").font(.headline)
                TextField("Photon URL", text: $endpoint, axis: .vertical)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                    .accessibilityIdentifier("photon-url")
                Text("Use the public Photon service or your own instance.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button(isTesting ? "Testing…" : "Test & Save") { isTesting = true }
                        .disabled(isTesting || locations == nil)
                        .buttonStyle(.glass)
                    Button("Reset to Default") {
                        endpoint = MapsPlacesPreferences.defaultEndpoint
                        saveEndpoint()
                    }
                    .buttonStyle(.glass)
                    .disabled(isTesting)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Place-name Language").font(.headline)
                LabeledContent("Default", value: "English")
                Text("Applies to the full location and address. Add a country to use its local place names.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach((locations?.preferences.localCountries ?? []).sorted(), id: \.self) { code in
                    HStack {
                        Text(countryName(code))
                        Spacer()
                        Picker("Language for \(countryName(code))", selection: languageBinding(code)) {
                            ForEach(PlaceLanguage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                Button("Add Country", systemImage: "plus") { showsCountries = true }
                    .buttonStyle(.glass)
                    .disabled(locations == nil)
                Text("Local uses place names as written locally, such as 世纪公园 in China. Names may use more than one language.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            Link("Place data © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .font(.footnote)
            Text("Place names are provided by Photon. Map tiles use your Immich server’s configured source.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { endpoint = locations?.preferences.endpoint ?? MapsPlacesPreferences.defaultEndpoint }
        .task(id: isTesting) {
            guard isTesting, let locations else { return }
            let namespace = locations.namespace
            let testedEndpoint = endpoint
            do {
                guard try await locations.test(endpoint: testedEndpoint) else { throw PlaceLookupError.invalidResponse }
                guard !Task.isCancelled, namespace == locations.namespace else { return }
                var settings = locations.preferences
                settings.endpoint = testedEndpoint
                try locations.save(settings)
                message = "Connected. Instance saved."
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            isTesting = false
        }
        .sheet(isPresented: $showsCountries) {
            NavigationStack {
                List(countryCodes, id: \.self) { code in
                    Button(countryName(code)) {
                        guard let locations else { return }
                        var settings = locations.preferences
                        settings.localCountries.insert(code)
                        try? locations.save(settings)
                        showsCountries = false
                    }
                }
                .searchable(text: $search, prompt: "Country or region")
                .navigationTitle("Use Local Names")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsCountries = false } } }
            }
        }
    }

    private var countryCodes: [String] {
        Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .filter { !((locations?.preferences.localCountries ?? []).contains($0)) }
            .filter { search.isEmpty || countryName($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search) }
            .sorted { countryName($0).localizedStandardCompare(countryName($1)) == .orderedAscending }
    }

    private func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func languageBinding(_ code: String) -> Binding<PlaceLanguage> {
        Binding(get: { locations?.preferences.language(countryCode: code) ?? .english }, set: { language in
            guard let locations else { return }
            var settings = locations.preferences
            if language == .local {
                settings.localCountries.insert(code)
            } else {
                settings.localCountries.remove(code)
            }
            try? locations.save(settings)
        })
    }

    private func saveEndpoint() {
        guard let locations else { return }
        var settings = locations.preferences
        settings.endpoint = endpoint
        do {
            try locations.save(settings)
            message = "Default instance restored."
        } catch { message = error.localizedDescription }
    }
}
