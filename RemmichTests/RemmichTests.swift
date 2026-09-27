//
//  RemmichTests.swift
//  RemmichTests
//
//  Created by Ender Wang on 9/25/26.
//

import Testing
@testable import Remmich

struct RemmichTests {
    @Test @MainActor func destinationOrderMatchesImmichNavigation() {
        let destinations = AppDestination.allCases
        let titles = destinations.map(\.title)

        #expect(destinations == [.photos, .albums, .library, .search])
        #expect(titles == ["Photos", "Albums", "Library", "Search"])
    }

    @Test @MainActor func fixtureIdentifiersAreUnique() {
        let assetIDs = PreviewFixtures.assets.map(\.id)
        let albumIDs = PreviewFixtures.albums.map(\.id)
        let collectionIDs = PreviewFixtures.collections.map(\.id)

        #expect(Set(assetIDs).count == assetIDs.count)
        #expect(Set(albumIDs).count == albumIDs.count)
        #expect(Set(collectionIDs).count == collectionIDs.count)
    }

    @Test @MainActor func fixtureLibraryCoversReadOnlyDestinations() {
        let hasPhotoSections = !PreviewFixtures.photoSections.isEmpty
        let hasSharedAlbum = PreviewFixtures.albums.contains { $0.isShared }
        let collectionKinds = Set(PreviewFixtures.collections.map(\.kind))

        #expect(hasPhotoSections)
        #expect(hasSharedAlbum)
        #expect(collectionKinds == Set(FixtureCollectionKind.allCases))
    }
}
