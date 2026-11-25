import Foundation
import Testing
@testable import ImmichAPI

struct LibraryReadTests {
    @Test(arguments: [
        ImmichTimelineQuery(orderBy: .createdAt, visibility: nil, includesPartners: false),
        ImmichTimelineQuery(visibility: nil, includesPartners: false, isFavorite: true),
        ImmichTimelineQuery(visibility: .archive, includesPartners: false),
        ImmichTimelineQuery(visibility: nil, includesTrashed: true, includesPartners: false),
        ImmichTimelineQuery(visibility: nil, includesPartners: false, personID: "person-1"),
        ImmichTimelineQuery(includesPartners: false, userID: "partner-1"),
    ])
    func appliesCollectionFiltersToBothTimelineReads(query: ImmichTimelineQuery) async throws {
        let emptyBucket = #"{"createdAt":[],"duration":[],"fileCreatedAt":[],"id":[],"isFavorite":[],"isImage":[],"isTrashed":[],"livePhotoVideoId":[],"localOffsetHours":[],"ownerId":[],"projectionType":[],"ratio":[],"thumbhash":[],"visibility":[]}"#
        let client = try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("token"),
                                      transport: ImmichQueuedGETTransport { request, operation in
                                          #expect(request.httpMethod == "GET")
                                          let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                                          let items = Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value ?? "") })
                                          #expect(items["orderBy"] == (query.orderBy == .createdAt ? "createdAt" : "takenAt"))
                                          #expect(items["visibility"] == query.visibility?.serverValue)
                                          #expect(items["isFavorite"] == query.isFavorite.map(String.init))
                                          #expect(items["isTrashed"] == String(query.includesTrashed))
                                          #expect(items["personId"] == query.personID)
                                          #expect(items["userId"] == query.userID)
                                          #expect(items["withPartners"] == "false")
                                          let body = operation == "getTimeBuckets" ? "[]" : emptyBucket
                                          return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
                                      })
        #expect(try await client.timelineBuckets(query: query).isEmpty)
        #expect(try await client.timelineAssets(in: "2026-11-01", query: query).isEmpty)
    }

    @Test func requestsOnlyIncomingPartnerRelationships() async throws {
        let client = try Self.client { request, operation in
            #expect(operation == "getPartners")
            #expect(request.url?.query == "direction=shared-with")
            return #" [{"id":"partner-1","name":"Lina","email":"lina@example.com","avatarColor":"primary","inTimeline":false,"profileChangedAt":"2026-11-01T00:00:00Z","profileImagePath":"uploaded-avatar"}] "#
        }
        let partners = try await client.incomingPartners()
        #expect(partners.map(\.id) == ["partner-1"])
        #expect(partners.first?.hasProfileImage == true)
    }

    @Test(arguments: [
        ("https://share.example.com", "https://share.example.com/s/summer%2Ftrip"),
        ("", "https://photos.example.com/immich/s/summer%2Ftrip"),
    ])
    func shareURLPrefersTheConfiguredDomainAndEncodesTheSlug(externalDomain: String, expected: String) async throws {
        let client = try Self.client { _, operation in
            if operation == "getUserConfig" {
                return userConfigFixture(externalDomain: externalDomain)
            }
            #expect(operation == "getAllSharedLinks")
            return #" [{"id":"link-1","description":"Trail","password":"protected","userId":"owner","key":"unused-key","type":"INDIVIDUAL","createdAt":"2026-11-01T00:00:00Z","expiresAt":null,"assets":[],"allowUpload":false,"allowDownload":true,"showMetadata":false,"slug":"summer/trip"}] "#
        }
        let serverURL = try #require(URL(string: "https://photos.example.com/immich/api"))
        let link = try #require(await client.sharedLinks(serverURL: serverURL).first)
        #expect(link.publicURL?.absoluteString == expected)
        #expect(link.isPasswordProtected)
    }

    @Test func folderReadKeepsOnlyTheExactParentReturnedByImmich() async throws {
        let client = try Self.client { request, operation in
            if operation == "getUniqueOriginalPaths" {
                return #"["/photos/Trip_%"]"#
            }
            #expect(operation == "getAssetsByOriginalPath")
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first?.value
            #expect(path == "/photos/Trip_%")
            let rows = [
                Self.assetJSON(id: "exact", path: "/photos/Trip_%/image.jpg"),
                Self.assetJSON(id: "similar", path: "/other/photos/Trip_%/image.jpg"),
                Self.assetJSON(id: "child", path: "/photos/Trip_%/day/image.jpg"),
            ]
            return "[" + rows.joined(separator: ",") + "]"
        }
        #expect(try await client.folderPaths() == ["/photos/Trip_%"])
        #expect(try await client.folderAssets(path: "/photos/Trip_%").map(\.id) == ["exact"])
    }

    @Test func stackLookupUsesAssetDetailsAndReadsMembersWithoutMutation() async throws {
        let stack = #"{"id":"stack-1","assetCount":2,"primaryAssetId":"cover"}"#
        let cover = Self.assetJSON(id: "cover", path: "/photos/cover.jpg")
        let member = Self.assetJSON(id: "member", path: "/photos/member.jpg")
        let trashed = Self.assetJSON(id: "trash", path: "/photos/trash.jpg")
            .replacingOccurrences(of: #""isTrashed":false"#, with: #""isTrashed":true"#)
        let stackResponse = #"{"id":"stack-1","primaryAssetId":"cover","assets":["# + [cover, member, trashed].joined(separator: ",") + "]}"
        let client = try Self.client { request, operation in
            if operation == "getAssetInfo" {
                #expect(request.url?.path == "/api/assets/cover")
                return String(cover.dropLast()) + #","stack":"# + stack + "}"
            }
            if operation == "searchStacks" {
                #expect(request.url?.path == "/api/stacks")
                return "[" + stackResponse + "]"
            }
            #expect(operation == "getStack")
            #expect(request.url?.path == "/api/stacks/stack-1")
            return stackResponse
        }
        let memberships = try await client.stackMemberships()
        #expect(memberships.first?.primaryAssetID == "cover")
        #expect(memberships.first?.assetIDs == ["cover", "member"])
        let detail = try await client.assetInfo(id: "cover")
        let stackID = try #require(detail.stackID)
        let members = try await client.stackAssets(for: detail.id, stackID: stackID)
        #expect(members.map(\.id) == ["cover", "member"])
        #expect(members.allSatisfy { $0.stack == ImmichTimelineStack(id: "stack-1", assetCount: 2, primaryAssetID: "cover") })
        #expect(try await client.stackAssets(for: "unrelated", stackID: stackID).isEmpty)
    }

    @Test(arguments: [(true, false), (false, true)])
    func libraryAvailabilityUsesFeaturePreferences(enabled: Bool, sidebarWeb: Bool) async throws {
        let client = try Self.client { request, operation in
            #expect(operation == "getMyPreferences")
            #expect(request.url?.path == "/api/users/me/preferences")
            return #"""
            {
              "albums":{"defaultAssetOrder":"desc"},
              "cast":{"gCastEnabled":false},
              "download":{"archiveSize":100000,"includeEmbeddedVideos":false},
              "emailNotifications":{"enabled":false,"albumInvite":false,"albumUpdate":false},
              "folders":{"enabled":\#(enabled),"sidebarWeb":\#(sidebarWeb)},
              "memories":{"enabled":\#(!enabled),"duration":5,"sidebarWeb":\#(!sidebarWeb)},
              "people":{"enabled":\#(enabled),"sidebarWeb":\#(sidebarWeb)},
              "purchase":{"showSupportBadge":false,"hideBuyButtonUntil":""},
              "ratings":{"enabled":false},
              "recentlyAdded":{"sidebarWeb":false},
              "sharedLinks":{"enabled":\#(!enabled),"sidebarWeb":\#(!sidebarWeb)},
              "tags":{"enabled":true,"sidebarWeb":false}
            }
            """#
        }
        let preferences = try await client.libraryPreferences()
        #expect(preferences.foldersEnabled == enabled)
        #expect(preferences.sharedLinksEnabled == !enabled)
        #expect(preferences.memoriesEnabled == !enabled)
        #expect(preferences.peopleEnabled == enabled)
    }

    private static func client(
        body: @escaping @Sendable (URLRequest, String) -> String
    ) throws -> ImmichClient {
        try ImmichClient(apiURL: #require(URL(string: "https://example.com/api")), credential: .bearer("token"),
                         transport: ImmichQueuedGETTransport { request, operation in
                             #expect(request.httpMethod == "GET")
                             #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                             return (Data(body(request, operation).utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                                          httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
                         })
    }

    private static func assetJSON(id: String, path: String) -> String {
        #"{"id":"\#(id)","originalPath":"\#(path)","checksum":"check","createdAt":"2026-11-01T00:00:00Z","fileCreatedAt":"2026-11-01T00:00:00Z","fileModifiedAt":"2026-11-01T00:00:00Z","hasMetadata":false,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,"isTrashed":false,"localDateTime":"2026-11-01T00:00:00Z","originalFileName":"image.jpg","ownerId":"owner","type":"IMAGE","updatedAt":"2026-11-01T00:00:00Z","visibility":"timeline"}"#
    }
}
