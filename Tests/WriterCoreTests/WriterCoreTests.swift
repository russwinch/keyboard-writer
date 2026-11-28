import Foundation
import XCTest

@testable import WriterCore

final class WriterCoreTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    let targets = try! Targets.load(from: repo.appendingPathComponent("targets.json"))
    let fast = FlashTiming(poll: 0.02, settle: 0, restart: 1)
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("writer-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func keyboard(_ id: String) -> Keyboard { targets.keyboards.first { $0.id == id }! }

    /// A folder of files named the way CI names them.
    func firmwareFolder(_ names: [String] = [
        "waterfowl_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
        "waterfowl_left nice_view_adapter nice_view-nice_nano__zmk-zmk.uf2",
        "waterfowl_left_peripheral_for_dongle.uf2",
        "waterfowl_right-nice_nano__zmk-zmk.uf2",
        "settings_reset-nice_nano__zmk-zmk.uf2",
        "settings_reset-xiao_ble__zmk-zmk.uf2",
    ]) throws -> [URL] {
        let folder = scratch.appendingPathComponent("firmware")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        return try Firmware.unpack(folder)
    }

    /// Plays a board: shows up as a bootloader drive, and goes away once a .uf2 lands on it.
    func board(_ info: String, in volumes: URL, named name: String = "BOOT") -> Task<String?, Error> {
        Task {
            let drive = volumes.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            try Data(info.utf8).write(to: drive.appendingPathComponent("INFO_UF2.TXT"))
            for _ in 0..<500 {
                let files = try FileManager.default.contentsOfDirectory(atPath: drive.path)
                if let uf2 = files.first(where: { $0.hasSuffix(".uf2") }) {
                    try FileManager.default.removeItem(at: drive)
                    return uf2
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
    }

    func testFileNames() {
        let built = Firmware.key(for: URL(fileURLWithPath: "/x/waterfowl_left nice_view_adapter nice_view-nice_nano__zmk-zmk.uf2"))
        XCTAssertEqual(built.firmware, "waterfowl_left")
        XCTAssertEqual(built.board, "nice_nano")
        let named = Firmware.key(for: URL(fileURLWithPath: "/x/waterfowl_left_peripheral_for_dongle.uf2"))
        XCTAssertEqual(named.firmware, "waterfowl_left_peripheral_for_dongle")
        XCTAssertNil(named.board)
    }

    func testPlanWithResetIsInOrder() throws {
        let plan = try Firmware.plan(keyboard: keyboard("waterfowl-dongle"), reset: true, files: firmwareFolder())
        XCTAssertEqual(plan.map(\.device.name), ["dongle", "dongle", "left", "left", "right", "right"])
        XCTAssertEqual(plan.map(\.kind), [.settingsReset, .firmware, .settingsReset, .firmware, .settingsReset, .firmware])
        XCTAssertEqual(plan.map(\.uf2.lastPathComponent), [
            "settings_reset-xiao_ble__zmk-zmk.uf2",
            "waterfowl_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
            "settings_reset-nice_nano__zmk-zmk.uf2",
            "waterfowl_left_peripheral_for_dongle.uf2",
            "settings_reset-nice_nano__zmk-zmk.uf2",
            "waterfowl_right-nice_nano__zmk-zmk.uf2",
        ])
    }

    /// Every keyboard's dongle variant picks its own files out of a whole
    /// release, not the plain keyboard's left half.
    func testDongleVariantsPickTheirFiles() throws {
        let release = try firmwareFolder([
            "urchin_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
            "urchin_left nice_view_adapter nice_view_gem-nice_nano__zmk-zmk.uf2",
            "urchin_left_peripheral_for_dongle.uf2",
            "urchin_right nice_view_adapter nice_view_gem-nice_nano__zmk-zmk.uf2",
            "splitkb_aurora_corne_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
            "splitkb_aurora_corne_left nice_view_adapter nice_view_gem-nice_nano__zmk-zmk.uf2",
            "splitkb_aurora_corne_left_peripheral_for_dongle.uf2",
            "splitkb_aurora_corne_right nice_view_adapter nice_view_gem-nice_nano__zmk-zmk.uf2",
            "forager_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
            "forager_left rgbled_adapter-xiao_ble__zmk-zmk.uf2",
            "forager_left_peripheral_for_dongle.uf2",
            "forager_right rgbled_adapter-xiao_ble__zmk-zmk.uf2",
            "settings_reset-nice_nano__zmk-zmk.uf2",
            "settings_reset-xiao_ble__zmk-zmk.uf2",
        ])
        let expected = [
            "urchin-dongle": [
                "urchin_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
                "urchin_left_peripheral_for_dongle.uf2",
                "urchin_right nice_view_adapter nice_view_gem-nice_nano__zmk-zmk.uf2",
            ],
            "aurora-dongle": [
                "splitkb_aurora_corne_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
                "splitkb_aurora_corne_left_peripheral_for_dongle.uf2",
                "splitkb_aurora_corne_right nice_view_adapter nice_view_gem-nice_nano__zmk-zmk.uf2",
            ],
            "forager-dongle": [
                "forager_dongle prospector_adapter-xiao_ble__zmk-zmk.uf2",
                "forager_left_peripheral_for_dongle.uf2",
                "forager_right rgbled_adapter-xiao_ble__zmk-zmk.uf2",
            ],
        ]
        for (variantID, files) in expected {
            let variant = keyboard(variantID)
            XCTAssertEqual(variant.devices.map(\.name), ["dongle", "left", "right"], variantID)
            let plan = try Firmware.plan(keyboard: variant, reset: false, files: release)
            XCTAssertEqual(plan.map(\.uf2.lastPathComponent), files, variantID)

            let plain = keyboard(String(variantID.dropLast("-dongle".count)))
            XCTAssertTrue(variant.devices[1].runs(shield: plain.devices[0].firmware), variantID)
            XCTAssertTrue(variant.devices[2].runs(shield: plain.devices[1].firmware), variantID)
            XCTAssertFalse(variant.devices[1].runs(shield: plain.devices[1].firmware), variantID)
            XCTAssertTrue(variant.devices[0].runs(shield: variant.devices[0].firmware), variantID)
        }

        let withReset = try Firmware.plan(keyboard: keyboard("forager-dongle"), reset: true, files: release)
        XCTAssertEqual(withReset.filter { $0.kind == .settingsReset }.map(\.uf2.lastPathComponent),
                       Array(repeating: "settings_reset-xiao_ble__zmk-zmk.uf2", count: 3))
    }

    func testPlanForSomeDevices() throws {
        let plan = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["right"], reset: false, files: firmwareFolder())
        XCTAssertEqual(plan.map(\.uf2.lastPathComponent), ["waterfowl_right-nice_nano__zmk-zmk.uf2"])
        XCTAssertThrowsError(try Firmware.plan(keyboard: keyboard("waterfowl"), only: [], reset: false, files: firmwareFolder()))
    }

    func testMissingFirmware() throws {
        XCTAssertThrowsError(try Firmware.plan(keyboard: keyboard("urchin"), reset: false, files: firmwareFolder())) {
            guard case FlashError.firmwareNotFound = $0 else { return XCTFail("\($0)") }
        }
    }

    func testFlashCopiesOntoTheDrive() async throws {
        let step = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["left"], reset: false, files: firmwareFolder())[0]
        let volumes = scratch.appendingPathComponent("volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        let seen = Recorder()

        let nano = board("UF2 Bootloader\nModel: nice!nano\nBoard-ID: nRF52840-nicenano", in: volumes)
        try await flash(step, roots: [volumes], boards: targets.boards, timing: fast) { await seen.add($0) }

        let copied = try await nano.value
        XCTAssertEqual(copied, step.uf2.lastPathComponent)
        let statuses = await seen.statuses
        XCTAssertEqual(statuses.suffix(3), [.copying, .restarting, .done])
    }

    func testWrongBoardIsLeftAlone() async throws {
        let step = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["left"], reset: false, files: firmwareFolder())[0]
        let volumes = scratch.appendingPathComponent("volumes")
        let xiao = volumes.appendingPathComponent("XIAO-SENSE")
        try FileManager.default.createDirectory(at: xiao, withIntermediateDirectories: true)
        try Data("Model: Seeed XIAO nRF52840".utf8).write(to: xiao.appendingPathComponent("INFO_UF2.TXT"))
        let seen = Recorder()

        let flashing = Task {
            try await flash(step, roots: [volumes], boards: targets.boards, timing: fast) { await seen.add($0) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        var statuses = await seen.statuses
        XCTAssertEqual(statuses, [.wrongBoard("xiao_ble")])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: xiao.path), ["INFO_UF2.TXT"])

        // Swap it for the right board and it carries on.
        try FileManager.default.removeItem(at: xiao)
        let nano = board("Model: nice!nano", in: volumes, named: "NICENANO")
        try await flashing.value
        let copied = try await nano.value
        XCTAssertEqual(copied, step.uf2.lastPathComponent)
        statuses = await seen.statuses
        XCTAssertEqual(statuses.last, .done)
    }

    func testUnreadableDriveIsSaidAndLeftAlone() async throws {
        let step = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["left"], reset: false, files: firmwareFolder())[0]
        let volumes = scratch.appendingPathComponent("volumes")
        let drive = volumes.appendingPathComponent("NICENANO")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let info = drive.appendingPathComponent("INFO_UF2.TXT")
        try Data("Model: nice!nano".utf8).write(to: info)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: info.path)
        let seen = Recorder()
        let ports = FakePorts(["/dev/d": "waterfowl_left"])

        let flashing = Task {
            try await flash(step, roots: [volumes], boards: targets.boards, ports: ports, timing: fast) {
                await seen.add($0)
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        var statuses = await seen.statuses
        XCTAssertEqual(statuses, [.unreadable("NICENANO")])
        XCTAssertEqual(ports.entered, [])  // nothing is sent to its bootloader meanwhile

        // Allowed to read it, it carries on.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: info.path)
        let watching = Task { () -> Bool in
            while FileManager.default.fileExists(atPath: drive.path) {
                if (try? FileManager.default.contentsOfDirectory(atPath: drive.path))?.contains(step.uf2.lastPathComponent) == true {
                    try FileManager.default.removeItem(at: drive)
                    return true
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }
        try await flashing.value
        let copied = try await watching.value
        XCTAssertTrue(copied)
        statuses = await seen.statuses
        XCTAssertEqual(statuses.last, .done)
    }

    func testDriveThatStaysIsAnError() async throws {
        let step = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["left"], reset: false, files: firmwareFolder())[0]
        let drive = scratch.appendingPathComponent("volumes/NICENANO")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("Model: nice!nano".utf8).write(to: drive.appendingPathComponent("INFO_UF2.TXT"))
        do {
            try await flash(
                step, roots: [drive.deletingLastPathComponent()], boards: targets.boards,
                timing: FlashTiming(poll: 0.02, settle: 0, restart: 0.1)) { _ in }
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? FlashError, .stillMounted("NICENANO"))
        }
    }

    func testDeviceIsAskedOverUSB() async throws {
        let step = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["left"], reset: false, files: firmwareFolder())[0]
        let volumes = scratch.appendingPathComponent("volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        let seen = Recorder()

        // Other devices are plugged in too: none of them is touched.
        let ports = FakePorts(["/dev/a": "waterfowl_right", "/dev/b": "urchin_left", "/dev/c": nil])
        let flashing = Task {
            try await flash(step, roots: [volumes], boards: targets.boards, ports: ports, timing: fast) {
                await seen.add($0)
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ports.entered, [])
        var statuses = await seen.statuses
        XCTAssertEqual(statuses, [.waiting])

        // The left half is plugged in: it is sent to its bootloader and flashed.
        var nano: Task<String?, Error>?
        ports.plug("/dev/d", "waterfowl_left") { nano = self.board("Model: nice!nano", in: volumes) }
        try await flashing.value
        XCTAssertEqual(ports.entered, ["/dev/d"])
        let copied = try await nano?.value
        XCTAssertEqual(copied, step.uf2.lastPathComponent)
        statuses = await seen.statuses
        XCTAssertEqual(statuses.suffix(4), [.starting, .copying, .restarting, .done])
    }

    func testDeviceIsSentToItsBootloaderOnce() async throws {
        let step = try Firmware.plan(keyboard: keyboard("waterfowl"), only: ["left"], reset: false, files: firmwareFolder())[0]
        let volumes = scratch.appendingPathComponent("volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        let ports = FakePorts([:])

        // Sent to its bootloader, but no drive turns up and it restarts its firmware.
        ports.plug("/dev/d", "waterfowl_left") {}
        let flashing = Task {
            try await flash(step, roots: [volumes], boards: targets.boards, ports: ports, timing: fast) { _ in }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        ports.plug("/dev/d", "waterfowl_left") {}
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ports.entered, ["/dev/d"])  // left running, not sent again

        // A double-tap still gets it flashed.
        let nano = board("Model: nice!nano", in: volumes)
        try await flashing.value
        let copied = try await nano.value
        XCTAssertEqual(copied, step.uf2.lastPathComponent)
    }

    func testGreeting() {
        XCTAssertEqual(USBSerialPorts.name(in: "keyboard-writer waterfowl_left"), "waterfowl_left")

        let left = keyboard("waterfowl-dongle").devices[1]
        XCTAssertTrue(left.runs(shield: "waterfowl_left"))
        XCTAssertTrue(left.runs(shield: "settings_reset"))
        XCTAssertFalse(left.runs(shield: "waterfowl_right"))
        XCTAssertTrue(keyboard("waterfowl-dongle").devices[0].runs(shield: "waterfowl_dongle"))
        // a dongle moved from one keyboard to another is still found
        let urchinDongle = keyboard("urchin-dongle").devices[0]
        XCTAssertTrue(urchinDongle.runs(shield: "waterfowl_dongle"))
        XCTAssertTrue(urchinDongle.runs(shield: "forager_dongle"))
        XCTAssertFalse(urchinDongle.runs(shield: "waterfowl_left"))
        // but a half isn't taken for a dongle, nor for another keyboard's half
        XCTAssertFalse(left.runs(shield: "urchin_dongle"))
        XCTAssertFalse(left.runs(shield: "urchin_left"))
        XCTAssertEqual(USBSerialPorts.name(in: "keyboard-writer"), "")
        XCTAssertNil(USBSerialPorts.name(in: "ok"))
        XCTAssertNil(USBSerialPorts.name(in: ""))
    }

    // MARK: Builds from the config repo

    func testBuildsFromReleases() throws {
        func release(_ id: Int, _ name: String, at time: String, prerelease: Bool = false, draft: Bool = false, asset: String? = "firmware.zip") -> String {
            let assets = asset.map {
                #"[{"name": "\#($0)", "browser_download_url": "https://github.com/o/r/releases/download/build-\#(id)/\#($0)"}]"#
            } ?? "[]"
            let target = id == 2 ? "main" : String(repeating: String(id), count: 40)
            return #"""
                {"id": \#(id), "name": "\#(name)", "tag_name": "build-\#(id)", "target_commitish": "\#(target)", "draft": \#(draft),
                 "prerelease": \#(prerelease), "created_at": "\#(time)", "published_at": "\#(time)",
                 "assets": \#(assets), "something_else": null}
                """#
        }
        let json = "[" + [
            release(1, "main · Older", at: "2026-11-01T10:00:00Z"),
            release(4, "branch · Newest", at: "2026-11-04T10:00:00Z", prerelease: true),
            release(3, "main · Newer", at: "2026-11-03T10:00:00Z"),
            release(5, "main · Draft", at: "2026-11-05T10:00:00Z", draft: true),
            release(6, "main · No firmware", at: "2026-11-06T10:00:00Z", asset: nil),
            release(2, "", at: "2026-11-02T10:00:00Z"),
        ].joined(separator: ",") + "]"

        let builds = try Builds.parse(Data(json.utf8))
        XCTAssertEqual(builds.map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(builds.map(\.title), ["branch · Newest", "main · Newer", "build-2", "main · Older"])
        XCTAssertEqual(builds.map(\.number), [4, 3, 2, 1])
        XCTAssertEqual(builds.map(\.label), ["4 · branch · Newest", "3 · main · Newer", "build-2", "1 · main · Older"])
        XCTAssertNil(Builds.number(inTag: "v1.2"))
        XCTAssertNil(Builds.number(inTag: "build-x"))
        XCTAssertEqual(builds[0].zip.absoluteString, "https://github.com/o/r/releases/download/build-4/firmware.zip")
        XCTAssertFalse(builds[0].main)
        XCTAssertEqual(builds[0].commit, String(repeating: "4", count: 40))
        XCTAssertNil(builds[2].commit)  // a branch name, not a commit
        XCTAssertEqual(Builds.shown(builds, branches: true).map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(Builds.shown(builds, branches: false).map(\.id), [3, 2, 1])
        XCTAssertEqual(try Builds.parse(Data("[]".utf8)), [])
    }

    func testBuildsPreferFirmwareZip() throws {
        func release(_ id: Int, _ assets: [String]) -> String {
            let list = assets.map {
                #"{"name": "\#($0)", "browser_download_url": "https://github.com/o/r/releases/download/build-\#(id)/\#($0)"}"#
            }.joined(separator: ",")
            return #"""
                {"id": \#(id), "name": "main · x", "tag_name": "build-\#(id)", "target_commitish": "main", "draft": false,
                 "prerelease": false, "created_at": "2026-11-0\#(id)T10:00:00Z", "assets": [\#(list)]}
                """#
        }
        // another .zip (the dongles' .elf, say) ahead of the firmware's
        let json = "[" + [release(2, ["dongle-elf.zip", "firmware.zip", "a.uf2"]), release(1, ["other.zip"])]
            .joined(separator: ",") + "]"
        let builds = try Builds.parse(Data(json.utf8))
        XCTAssertEqual(builds.map { $0.zip.lastPathComponent }, ["firmware.zip", "other.zip"])
    }

    func testResetTags() throws {
        let json = #"""
            [{"ref": "refs/tags/settings-reset/dongle-central", "object": {"sha": "abc", "type": "commit"}},
             {"ref": "refs/tags/settings-reset/annotated", "object": {"sha": "def", "type": "tag"}},
             {"ref": "refs/tags/settings-reset/", "object": {"sha": "ghi", "type": "commit"}}]
            """#
        let tags = try Builds.parseResetTags(Data(json.utf8))
        XCTAssertEqual(tags, [
            ResetTag(name: "settings-reset/dongle-central", commit: "abc"),
            ResetTag(name: "settings-reset/", commit: "ghi"),
        ])
        XCTAssertEqual(tags.map(\.why), ["dongle central", ""])
        XCTAssertEqual(try Builds.parseResetTags(Data("[]".utf8)), [])

        func compared(_ status: String) throws -> Bool {
            try Builds.isAncestor(compared: Data(#"{"status": "\#(status)", "commits": []}"#.utf8))
        }
        XCTAssertTrue(try compared("ahead"))
        XCTAssertTrue(try compared("identical"))
        XCTAssertFalse(try compared("behind"))
        XCTAssertFalse(try compared("diverged"))
    }

    func testDownloadedBuildIsKept() async throws {
        let build = Build(id: 7, title: "main · Here already", date: Date(), main: true,
                          zip: URL(string: "https://example.invalid/firmware.zip")!)
        try Data("zip".utf8).write(to: scratch.appendingPathComponent("build-7.zip"))
        let file = try await Builds.download(build, into: scratch)
        XCTAssertEqual(try Data(contentsOf: file), Data("zip".utf8))
    }
}

actor Recorder {
    var statuses: [StepStatus] = []
    func add(_ status: StepStatus) { statuses.append(status) }
}

/// Pretend serial ports: path -> what the device says it is (nil: not a keyboard).
final class FakePorts: SerialPorts, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String?]
    private var onEnter: [String: () -> Void] = [:]
    private var enteredPaths: [String] = []

    init(_ names: [String: String?]) { self.names = names }

    var entered: [String] { lock.withLock { enteredPaths } }

    func plug(_ path: String, _ name: String, onEnter: @escaping () -> Void) {
        lock.withLock {
            names[path] = .some(name)
            self.onEnter[path] = onEnter
        }
    }

    func paths() -> [String] { lock.withLock { names.keys.sorted() } }

    func probe(_ path: String, enter: (String) -> Bool) -> String? {
        let (name, action) = lock.withLock { (names[path] ?? nil, onEnter[path]) }
        guard let name else { return nil }
        if enter(name) {
            lock.withLock {
                enteredPaths.append(path)
                names[path] = nil  // it restarts, so the port goes away
            }
            action?()
        }
        return name
    }
}
