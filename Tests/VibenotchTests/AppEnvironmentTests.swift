import Foundation
import Testing
@testable import Vibenotch

@Test func spoolURLIsInHomeDirectory() {
    let environment = AppEnvironment()
    let spoolPath = environment.spoolURL.standardizedFileURL.path
    let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    #expect(spoolPath.hasSuffix("/.vibenotch/sessions"))
    #expect(spoolPath.hasPrefix(homePath + "/"))
    #expect(environment.pendingURL.path.hasSuffix("/.vibenotch/pending"))
    #expect(environment.decisionsURL.path.hasSuffix("/.vibenotch/decisions"))
}
