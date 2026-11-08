import Foundation
import Testing
@testable import Remmich

struct OnboardingServerDefaultsTests {
    @Test func emptyAddressUsesDemoButExplicitServersArePreserved() {
        #expect(OnboardingServerDefaults.address("") == "https://demo.immich.app")
        #expect(OnboardingServerDefaults.address(" \n ") == "https://demo.immich.app")
        #expect(OnboardingServerDefaults.address(" https://photos.example/immich ") == "https://photos.example/immich")
    }

    @Test(arguments: ["https://demo.immich.app", "https://demo.immich.app/api", "https://demo.immich.app:443/api/"])
    func demoOriginReceivesPublicCredentials(address: String) throws {
        #expect(try OnboardingServerDefaults.isDemo(#require(URL(string: address))))
        #expect(OnboardingServerDefaults.demoEmail == "demo@immich.app")
        #expect(OnboardingServerDefaults.demoPassword == "demo")
    }

    @Test(arguments: ["https://photos.example/api", "http://demo.immich.app/api", "https://demo.immich.app.evil.example/api",
                      "https://demo.immich.app:8443/api", "https://demo.immich.app/other/api", "https://user@demo.immich.app/api"])
    func customOriginsDoNotReceiveDemoCredentials(address: String) throws {
        #expect(try !OnboardingServerDefaults.isDemo(#require(URL(string: address))))
    }
}
