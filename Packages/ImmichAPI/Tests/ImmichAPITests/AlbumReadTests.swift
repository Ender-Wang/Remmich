import Foundation
import Testing
@testable import ImmichAPI

@Suite("Read-only album API")
struct AlbumReadTests {
    @Test func readsAlbumMetadataWithoutMutations() async throws {
        let json = #"{"id":"album-1","albumName":"Park","description":"A walk","albumThumbnailAssetId":null,"assetCount":0,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-02T00:00:00Z","shared":true,"hasSharedLink":false,"isActivityEnabled":false,"albumUsers":[{"role":"owner","user":{"id":"owner-1","name":"Owner","email":"owner@example.com","avatarColor":"primary","profileChangedAt":"2026-11-01T00:00:00Z","profileImagePath":""}}]}"#
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("token"),
                                      transport: ImmichQueuedGETTransport { request, operation in
                                          #expect(request.httpMethod == "GET")
                                          #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                                          #expect(["getAllAlbums", "getAlbumInfo"].contains(operation))
                                          let body = operation == "getAllAlbums" ? "[\(json)]" : json
                                          return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
                                      })
        let albums = try await client.albums()
        let album = try await client.album(id: "album-1")
        #expect(albums == [album])
        #expect(album.name == "Park")
        #expect(album.thumbnailAssetID == nil)
        #expect(album.ownerName == "Owner")
        #expect(album.isShared)
        #expect(album.createdAt < album.updatedAt)
        #expect(album.startDate == nil)
        #expect(album.endDate == nil)
    }

    @Test func scopesBucketsAndAssetsWithoutRootVisibilityFilter() async throws {
        let emptyBucket = #"{"createdAt":[],"duration":[],"fileCreatedAt":[],"id":[],"isFavorite":[],"isImage":[],"isTrashed":[],"livePhotoVideoId":[],"localOffsetHours":[],"ownerId":[],"projectionType":[],"ratio":[],"thumbhash":[],"visibility":[]}"#
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("token"),
                                      transport: ImmichQueuedGETTransport { request, operation in
                                          let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                                          #expect(items.contains { $0.name == "albumId" && $0.value == "album-1" })
                                          #expect(!items.contains { $0.name == "visibility" })
                                          #expect(items.contains { $0.name == "withStacked" && $0.value == "true" })
                                          let body = operation == "getTimeBuckets" ? "[]" : emptyBucket
                                          return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
                                      })
        let query = ImmichTimelineQuery(albumID: "album-1")
        #expect(try await client.timelineBuckets(query: query).isEmpty)
        #expect(try await client.timelineAssets(in: "2026-11-01", query: query).isEmpty)
    }

    @Test func rejectsAlbumReadsWithoutAuthentication() async throws {
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")))
        await #expect(throws: ImmichAPIError.unauthorized) { try await client.albums() }
        await #expect(throws: ImmichAPIError.unauthorized) { try await client.album(id: "album-1") }
    }
}
