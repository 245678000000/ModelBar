import CryptoKit
import Foundation
import Testing
@testable import ModelBarCore

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "modelbar updater \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 只有 Info.plist 和一个脚本的最小应用。
private func makeApp(at url: URL, identifier: String = "com.test.app", version: String) throws {
    let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
    let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": identifier,
        "CFBundleShortVersionString": version,
        "CFBundleExecutable": "app",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appending(path: "Info.plist"))
    let executable = macOS.appending(path: "app")
    try "#!/bin/sh\necho \(version)\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
}

private func version(ofApp url: URL) -> String? {
    Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
}

private func run(_ path: String, _ arguments: [String]) -> Int32 {
    ProcessRunner.run(URL(fileURLWithPath: path), arguments: arguments, timeout: 60).exitCode
}

private func sha256(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
}

private final class FakeTransport: UpdateTransport, @unchecked Sendable {
    let archive: URL?
    let checksums: Data
    private let lock = NSLock()
    private var calls = 0

    init(archive: URL?, checksums: Data) {
        self.archive = archive
        self.checksums = checksums
    }

    var callCount: Int { lock.withLock { calls } }

    func data(from url: URL) async throws -> Data {
        lock.withLock { calls += 1 }
        return checksums
    }

    func download(from url: URL) async throws -> URL {
        lock.withLock { calls += 1 }
        guard let archive else { throw UpdateError("网络错误") }
        let copy = FileManager.default.temporaryDirectory.appending(path: "modelbar-download-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: archive, to: copy)
        return copy
    }
}

private struct AllowAll: UpdateVerifier {
    func verify(app: URL) throws {}
}

private struct RejectAll: UpdateVerifier {
    func verify(app: URL) throws { throw UpdateError("签名不对") }
}

@Suite struct AppVersionTests {
    @Test func comparesNumerically() throws {
        #expect(try #require(AppVersion("1.2.0")) < #require(AppVersion("1.2.1")))
        #expect(try #require(AppVersion("1.9")) < #require(AppVersion("1.10")))
        #expect(try #require(AppVersion("1.2")) == #require(AppVersion("1.2.0")))
        #expect(try #require(AppVersion("2")) > #require(AppVersion("1.99.99")))
    }

    @Test(arguments: ["", "1.x", "1..2", "-1.0", "1.0-beta", "v1.0", " 1.0"])
    func rejectsInvalidText(text: String) {
        #expect(AppVersion(text) == nil)
    }
}

@Suite struct UpdateFeedTests {
    private func release(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        host: String = "https://github.com/o/r/releases/download",
        assets: [String] = [UpdateFeed.archiveName, UpdateFeed.checksumsName]
    ) -> [String: Any] {
        [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "html_url": "https://github.com/o/r/releases/tag/\(tag)",
            "assets": assets.map { ["name": $0, "browser_download_url": "\(host)/\(tag)/\($0)"] },
        ]
    }

    private func latest(_ releases: [[String: Any]], current: String = "1.2.0", allowsAnyHost: Bool = false) throws -> AppUpdate? {
        let data = try JSONSerialization.data(withJSONObject: releases)
        return try UpdateFeed.latest(in: data, newerThan: try #require(AppVersion(current)), allowsAnyHost: allowsAnyHost)
    }

    @Test func picksTheHighestNewerVersionInAnyOrder() throws {
        let update = try latest([release(tag: "mac-v1.3.0"), release(tag: "mac-v1.10.0"), release(tag: "mac-v1.9.0")])
        #expect(update?.version.description == "1.10.0")
        #expect(update?.archiveURL.lastPathComponent == UpdateFeed.archiveName)
        #expect(update?.checksumsURL.lastPathComponent == UpdateFeed.checksumsName)
    }

    @Test func ignoresReleasesThatDoNotApply() throws {
        #expect(try latest([
            release(tag: "mac-v9.0.0", draft: true),
            release(tag: "mac-v9.0.1", prerelease: true),
            release(tag: "v9.0.0"),
            release(tag: "win-v9.0.0"),
            release(tag: "mac-vnext"),
            release(tag: "mac-v1.2.0"),
            release(tag: "mac-v1.1.0"),
            release(tag: "mac-v9.0.2", assets: [UpdateFeed.checksumsName]),
            release(tag: "mac-v9.0.3", assets: [UpdateFeed.archiveName]),
        ]) == nil)
    }

    @Test func rejectsAssetsFromOtherHostsUnlessAllowed() throws {
        let local = release(tag: "mac-v2.0.0", host: "http://127.0.0.1:9000")
        let otherHost = release(tag: "mac-v2.0.0", host: "https://example.com")
        #expect(try latest([local]) == nil)
        #expect(try latest([otherHost]) == nil)
        #expect(try latest([local], allowsAnyHost: true)?.version.description == "2.0.0")
    }

    @Test func malformedFeedIsAnError() {
        #expect(throws: UpdateError.self) {
            try UpdateFeed.latest(in: Data("{}".utf8), newerThan: try #require(AppVersion("1.0")))
        }
    }

    @Test func sandboxOnlyUsesTheFeedItWasGiven() {
        let sandbox = AppPaths(home: FileManager.default.temporaryDirectory.appending(path: "modelbar-feed"))
        #expect(UpdateFeed.url(paths: sandbox, environment: [:]) == nil)
        #expect(UpdateFeed.url(paths: sandbox, environment: ["MODELBAR_UPDATE_FEED": "http://127.0.0.1:1/x"])?.port == 1)
        let real = AppPaths(home: FileManager.default.homeDirectoryForCurrentUser)
        #expect(UpdateFeed.url(paths: real, environment: ["MODELBAR_UPDATE_FEED": "http://127.0.0.1:1/x"])?.host == "api.github.com")
    }
}

@Suite struct UpdateInstallerTests {
    private struct Setup {
        let root: URL
        let app: URL
        let work: URL
        let update: AppUpdate
        let archive: URL
        let checksums: Data
    }

    /// 旧版 1.0.0 装在 Applications 里，服务器上有 2.0.0 的更新包。
    private func setup(identifier: String = "com.test.app", packagedVersion: String = "2.0.0", extraFile: Bool = false) throws -> Setup {
        let root = try makeDirectory()
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let app = applications.appending(path: "Test.app", directoryHint: .isDirectory)
        try makeApp(at: app, version: "1.0.0")

        let build = root.appending(path: "build", directoryHint: .isDirectory)
        try makeApp(at: build.appending(path: "Test.app", directoryHint: .isDirectory), identifier: identifier, version: packagedVersion)
        if extraFile { try "x".write(to: build.appending(path: "extra.txt"), atomically: true, encoding: .utf8) }
        let archive = root.appending(path: UpdateFeed.archiveName)
        #expect(run("/usr/bin/ditto", ["-c", "-k", build.path, archive.path]) == 0)
        let checksums = Data("\(try sha256(archive))  \(UpdateFeed.archiveName)\n".utf8)

        let base = URL(string: "https://github.com/o/r/releases/download/mac-v2.0.0/")!
        let update = AppUpdate(
            version: try #require(AppVersion("2.0.0")),
            archiveURL: base.appending(path: UpdateFeed.archiveName),
            checksumsURL: base.appending(path: UpdateFeed.checksumsName),
            pageURL: URL(string: "https://github.com/o/r/releases/tag/mac-v2.0.0")!
        )
        return Setup(root: root, app: app, work: root.appending(path: "work", directoryHint: .isDirectory),
                     update: update, archive: archive, checksums: checksums)
    }

    private func installer(_ setup: Setup, transport: (any UpdateTransport)? = nil, verifier: any UpdateVerifier = AllowAll()) -> UpdateInstaller {
        UpdateInstaller(
            appBundle: setup.app,
            bundleIdentifier: "com.test.app",
            workDirectory: setup.work,
            transport: transport ?? FakeTransport(archive: setup.archive, checksums: setup.checksums),
            verifier: verifier
        )
    }

    private func applicationsEntries(_ setup: Setup) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: setup.app.deletingLastPathComponent().path)
    }

    private func expectUntouched(_ setup: Setup) throws {
        #expect(version(ofApp: setup.app) == "1.0.0")
        #expect(try applicationsEntries(setup) == ["Test.app"])
    }

    @Test func prepareStagesTheNewAppBesideTheOldOne() async throws {
        let setup = try setup()
        let staged = try await installer(setup).prepare(setup.update)
        #expect(version(ofApp: staged) == "2.0.0")
        #expect(staged.deletingLastPathComponent().path == setup.app.deletingLastPathComponent().path)
        #expect(staged.lastPathComponent.hasPrefix("."))
        #expect(version(ofApp: setup.app) == "1.0.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.work.path).isEmpty)
    }

    @Test func wrongChecksumStopsBeforeTouchingAnything() async throws {
        let setup = try setup()
        let transport = FakeTransport(archive: setup.archive, checksums: Data("\(String(repeating: "0", count: 64))  \(UpdateFeed.archiveName)\n".utf8))
        await #expect(throws: UpdateError.self) { _ = try await installer(setup, transport: transport).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func missingChecksumEntryStopsTheUpdate() async throws {
        let setup = try setup()
        let transport = FakeTransport(archive: setup.archive, checksums: Data("abc  other.zip\n".utf8))
        await #expect(throws: UpdateError.self) { _ = try await installer(setup, transport: transport).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func downloadFailureLeavesTheOldVersion() async throws {
        let setup = try setup()
        let transport = FakeTransport(archive: nil, checksums: setup.checksums)
        await #expect(throws: UpdateError.self) { _ = try await installer(setup, transport: transport).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func archiveThatIsNotAZipStopsTheUpdate() async throws {
        let setup = try setup()
        let junk = setup.root.appending(path: "junk.zip")
        try "not a zip".write(to: junk, atomically: true, encoding: .utf8)
        let transport = FakeTransport(archive: junk, checksums: Data("\(try sha256(junk))  \(UpdateFeed.archiveName)\n".utf8))
        await #expect(throws: UpdateError.self) { _ = try await installer(setup, transport: transport).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func packageForAnotherAppIsRejected() async throws {
        let setup = try setup(identifier: "com.other.app")
        await #expect(throws: UpdateError.self) { _ = try await installer(setup).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func packageWithADifferentVersionIsRejected() async throws {
        let setup = try setup(packagedVersion: "1.5.0")
        await #expect(throws: UpdateError.self) { _ = try await installer(setup).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func packageWithExtraFilesIsRejected() async throws {
        let setup = try setup(extraFile: true)
        await #expect(throws: UpdateError.self) { _ = try await installer(setup).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func signatureRejectionStopsTheUpdate() async throws {
        let setup = try setup()
        await #expect(throws: UpdateError.self) { _ = try await installer(setup, verifier: RejectAll()).prepare(setup.update) }
        try expectUntouched(setup)
    }

    @Test func unwritableLocationFailsBeforeDownloading() async throws {
        let setup = try setup()
        let parent = setup.app.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        let transport = FakeTransport(archive: setup.archive, checksums: setup.checksums)
        await #expect(throws: UpdateError.self) { _ = try await installer(setup, transport: transport).prepare(setup.update) }
        #expect(transport.callCount == 0)
    }

    @Test(arguments: [
        "/private/var/folders/x/AppTranslocation/123/d/Test.app",
        "/Volumes/ModelBar/Test.app",
        "/Applications/NotABundle",
    ])
    func refusesToReplaceAppsThatAreNotInstalled(path: String) {
        let installer = UpdateInstaller(
            appBundle: URL(fileURLWithPath: path),
            bundleIdentifier: "com.test.app",
            workDirectory: FileManager.default.temporaryDirectory,
            transport: FakeTransport(archive: nil, checksums: Data()),
            verifier: AllowAll()
        )
        #expect(throws: UpdateError.self) { try installer.checkCanInstall() }
    }

    @Test func failureBeforeSwappingRemovesTheStagedCopyAndKeepsTheOldVersion() async throws {
        let setup = try setup()
        await #expect(throws: UpdateError.self) {
            try await installer(setup).install(setup.update) { throw UpdateError("同步没结束") }
        }
        try expectUntouched(setup)
    }

    @Test func swapInPutsTheNewVersionInPlaceAndKeepsTheOldOne() async throws {
        let setup = try setup()
        let installer = installer(setup)
        let staged = try await installer.prepare(setup.update)
        let backup = try installer.swapIn(staged)
        #expect(version(ofApp: setup.app) == "2.0.0")
        #expect(version(ofApp: backup) == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func swapInRestoresTheOldVersionWhenTheNewOneIsMissing() throws {
        let setup = try setup()
        let missing = setup.app.deletingLastPathComponent().appending(path: ".missing.app", directoryHint: .isDirectory)
        #expect(throws: (any Error).self) { _ = try installer(setup).swapIn(missing) }
        try expectUntouched(setup)
    }

    @Test func removeLeftoversOnlyTouchesItsOwnFiles() throws {
        let setup = try setup()
        let parent = setup.app.deletingLastPathComponent()
        for name in [".ModelBar-update-a.app", ".ModelBar-previous-b.app", "Other.app", ".ModelBar-update-notes.txt"] {
            try FileManager.default.createDirectory(at: parent.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: setup.work.appending(path: "old", directoryHint: .isDirectory), withIntermediateDirectories: true)
        installer(setup).removeLeftovers()
        #expect(try applicationsEntries(setup).sorted() == [".ModelBar-update-notes.txt", "Other.app", "Test.app"])
        #expect(!FileManager.default.fileExists(atPath: setup.work.path))
    }
}

@Suite struct SigningVerifierTests {
    private func signedApp() throws -> URL {
        let app = try makeDirectory().appending(path: "Test.app", directoryHint: .isDirectory)
        try makeApp(at: app, version: "1.0.0")
        #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
        return app
    }

    @Test func acceptsAnAppThatMeetsTheRequirement() throws {
        try SigningVerifier(requirementText: "identifier \"com.test.app\"").verify(app: try signedApp())
    }

    @Test func rejectsAnAppThatDoesNotMeetTheRequirement() throws {
        let app = try signedApp()
        #expect(throws: UpdateError.self) {
            try SigningVerifier(requirementText: "identifier \"com.other.app\"").verify(app: app)
        }
    }

    @Test func rejectsAnAppChangedAfterSigning() throws {
        let app = try signedApp()
        try "#!/bin/sh\necho changed\n".write(to: app.appending(path: "Contents/MacOS/app"), atomically: true, encoding: .utf8)
        #expect(throws: UpdateError.self) {
            try SigningVerifier(requirementText: "identifier \"com.test.app\"").verify(app: app)
        }
    }

    @Test func rejectsAnUnsignedApp() throws {
        let app = try makeDirectory().appending(path: "Test.app", directoryHint: .isDirectory)
        try makeApp(at: app, version: "1.0.0")
        #expect(throws: UpdateError.self) {
            try SigningVerifier(requirementText: "identifier \"com.test.app\"").verify(app: app)
        }
    }

    @Test func runningFromAnAdHocBuildCannotVerifyAnything() throws {
        let app = try signedApp()
        #expect(throws: UpdateError.self) {
            try SigningVerifier(requirementText: "cdhash H\"0000000000000000000000000000000000000000\"").verify(app: app)
        }
    }
}

@Suite struct UpdateSettingTests {
    @Test func checksForUpdatesByDefaultIncludingOlderSettingsFiles() throws {
        #expect(AppState().checksForUpdates)
        #expect(try JSONDecoder().decode(AppState.self, from: Data("{}".utf8)).checksForUpdates)
        #expect(try !JSONDecoder().decode(AppState.self, from: Data(#"{"checksForUpdates":false}"#.utf8)).checksForUpdates)
    }
}
