import Foundation
import XCTest

@testable import WriterCore

final class AppUpdatesTests: XCTestCase {
    let identifier = "com.github.russwinch.keyboard-writer"
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("update-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testReadsVersionsAndTags() {
        XCTAssertEqual(AppVersion("v1.12")?.numbers, [1, 12])
        XCTAssertEqual(AppVersion("1.12")?.numbers, [1, 12])
        XCTAssertEqual(AppVersion("0.0")?.isLocalBuild, true)
        XCTAssertEqual(AppVersion("v1.12")?.isLocalBuild, false)
        XCTAssertEqual(AppVersion("v1.12")?.description, "1.12")
        for malformed in ["", "v", "latest", "v1.", "1..2", "1.x", "-1.2", "+1.2", "v 1.2", "1.2-beta"] {
            XCTAssertNil(AppVersion(malformed), malformed)
        }
    }

    func testOrdersNumberByNumber() throws {
        let version = { (text: String) in try XCTUnwrap(AppVersion(text)) }
        XCTAssertGreaterThan(try version("1.10"), try version("1.9"))
        XCTAssertLessThan(try version("1.9"), try version("2.0"))
        XCTAssertLessThan(try version("1.2"), try version("1.2.1"))
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertFalse(try version("1.12") > version("v1.12"))
    }

    func latestRelease(tag: String, assets: [String]) -> Data {
        let assetJSON = assets.map { name in
            #"{"name": "\#(name)", "browser_download_url": "https://github.com/o/r/releases/download/\#(tag)/\#(name)"}"#
        }
        return Data(#"{"tag_name": "\#(tag)", "name": "Keyboard Writer", "assets": [\#(assetJSON.joined(separator: ","))]}"#.utf8)
    }

    func testPicksTheAppFromTheLatestRelease() throws {
        let release = try XCTUnwrap(AppUpdates.parseLatest(latestRelease(tag: "v1.12", assets: ["notes.zip", "Keyboard-Writer.zip"])))
        XCTAssertEqual(release.version, AppVersion("1.12"))
        XCTAssertEqual(release.zip.absoluteString, "https://github.com/o/r/releases/download/v1.12/Keyboard-Writer.zip")
        XCTAssertNil(try AppUpdates.parseLatest(latestRelease(tag: "v1.13", assets: ["notes.zip"])))
    }

    func testMalformedTagIsAnError() {
        XCTAssertThrowsError(try AppUpdates.parseLatest(latestRelease(tag: "nightly", assets: ["Keyboard-Writer.zip"])))
        XCTAssertThrowsError(try AppUpdates.parseLatest(Data("{}".utf8)))
    }

    /// A stand-in .app holding only an Info.plist and a marker file.
    func makeBundle(in folder: URL, name: String = AppUpdates.bundleName, identifier: String, marker: String) throws -> URL {
        let bundle = folder.appendingPathComponent(name)
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        return bundle
    }

    func marker(_ bundle: URL) throws -> String {
        String(decoding: try Data(contentsOf: bundle.appendingPathComponent("Contents/marker")), as: UTF8.self)
    }

    func testChecksTheBundleIsThisApp() throws {
        let good = try makeBundle(in: scratch.appendingPathComponent("good"), identifier: identifier, marker: "new")
        XCTAssertNoThrow(try AppUpdates.check(good, bundleIdentifier: identifier))
        let other = try makeBundle(in: scratch.appendingPathComponent("other"), identifier: "com.example.other", marker: "new")
        XCTAssertThrowsError(try AppUpdates.check(other, bundleIdentifier: identifier))
        let renamed = try makeBundle(in: scratch, name: "Something.app", identifier: identifier, marker: "new")
        XCTAssertThrowsError(try AppUpdates.check(renamed, bundleIdentifier: identifier))
        XCTAssertThrowsError(try AppUpdates.check(scratch.appendingPathComponent("missing/\(AppUpdates.bundleName)"),
                                                  bundleIdentifier: identifier))
    }

    func testSwapPutsTheNewBundleInPlace() throws {
        let applications = scratch.appendingPathComponent("Applications")
        let installed = try makeBundle(in: applications, identifier: identifier, marker: "old")
        let replacement = try makeBundle(in: scratch.appendingPathComponent("unpacked"), identifier: identifier, marker: "new")
        try AppUpdates.swap(installed, with: replacement)
        XCTAssertEqual(try marker(installed), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppUpdates.bundleName])
    }

    func testFailedSwapLeavesTheInstalledAppAlone() throws {
        let applications = scratch.appendingPathComponent("Applications")
        let installed = try makeBundle(in: applications, identifier: identifier, marker: "old")
        XCTAssertThrowsError(try AppUpdates.swap(installed, with: scratch.appendingPathComponent("nothing-here")))
        XCTAssertEqual(try marker(installed), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), [AppUpdates.bundleName])
    }

    #if os(macOS)
    func testUnpacksAReleaseZip() throws {
        let built = try makeBundle(in: scratch.appendingPathComponent("built"), identifier: identifier, marker: "new")
        let zip = scratch.appendingPathComponent(AppUpdates.assetName)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", built.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let unpacked = try AppUpdates.unpack(zip, into: scratch.appendingPathComponent("unpacked"))
        XCTAssertNoThrow(try AppUpdates.check(unpacked, bundleIdentifier: identifier))
        XCTAssertEqual(try marker(unpacked), "new")
        XCTAssertThrowsError(try AppUpdates.unpack(scratch.appendingPathComponent("missing.zip"),
                                                   into: scratch.appendingPathComponent("nothing")))
    }
    #endif
}
