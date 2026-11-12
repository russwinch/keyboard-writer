import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release version such as "1.12", compared number by number.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]

    /// Reads "1.12" or a tag such as "v1.12"; nil for anything else.
    public init?(_ text: String) {
        let bare = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        let allDigits = parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) } }
        guard allDigits else { return nil }
        let numbers = parts.compactMap { part in Int(part) }
        guard numbers.count == parts.count else { return nil }
        self.numbers = numbers
    }

    /// A build made without a version ("0.0"), as `build.sh` does locally.
    public var isLocalBuild: Bool { numbers.allSatisfy { $0 == 0 } }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let length = max(lhs.numbers.count, rhs.numbers.count)
        let padded = { (version: AppVersion) in version.numbers + Array(repeating: 0, count: length - version.numbers.count) }
        return padded(lhs).lexicographicallyPrecedes(padded(rhs))
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A published release of this app and its zipped .app.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let zip: URL

    public init(version: AppVersion, zip: URL) {
        self.version = version
        self.zip = zip
    }
}

public enum AppUpdates {
    public static let repo = "russwinch/keyboard-writer"
    /// The asset the App workflow attaches to each release.
    public static let assetName = "Keyboard-Writer.zip"
    public static let bundleName = "Keyboard Writer.app"

    public static let latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// GitHub's "latest release" answer; nil when it has no app attached.
    public static func parseLatest(_ data: Data) throws -> AppRelease? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let version = AppVersion(release.tag_name) else {
            throw FlashError.tool("The latest release's tag, \(release.tag_name), isn't a version.")
        }
        guard let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
        return AppRelease(version: version, zip: asset.browser_download_url)
    }

    /// The latest release when it is newer than `running`, otherwise nil.
    public static func newer(than running: AppVersion) async throws -> AppRelease? {
        guard let latest = try parseLatest(try await Builds.fetch(Builds.request(latestURL))) else { return nil }
        return latest.version > running ? latest : nil
    }

    /// Downloads and checks the release, then puts it in place of `installed`.
    /// Anything that fails before the swap leaves `installed` untouched.
    public static func install(_ release: AppRelease, replacing installed: URL, bundleIdentifier: String) async throws {
        let work = try Firmware.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(assetName)
        try await Builds.fetch(URLRequest(url: release.zip)).write(to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        let bundle = try unpack(zip, into: unpacked)
        try check(bundle, bundleIdentifier: bundleIdentifier)
        try swap(installed, with: bundle)
    }

    /// Unzips a release with ditto (which keeps the bundle's signature and
    /// permissions) and returns the app inside.
    static func unpack(_ zip: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw FlashError.tool("Couldn't unzip the update.")
        }
        return folder.appendingPathComponent(bundleName)
    }

    /// Fails unless `bundle` is this app: the expected name and identifier.
    static func check(_ bundle: URL, bundleIdentifier: String) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard bundle.lastPathComponent == bundleName,
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == bundleIdentifier
        else {
            throw FlashError.tool("The update isn't \(bundleName).")
        }
    }

    /// Replaces `installed` with `replacement`, putting the old one back if
    /// the last step fails. Both renames stay in `installed`'s folder.
    static func swap(_ installed: URL, with replacement: URL) throws {
        let files = FileManager.default
        let folder = installed.deletingLastPathComponent()
        let tag = UUID().uuidString
        let incoming = folder.appendingPathComponent(".\(installed.lastPathComponent).new-\(tag)")
        let outgoing = folder.appendingPathComponent(".\(installed.lastPathComponent).old-\(tag)")
        do {
            try files.moveItem(at: replacement, to: incoming)
        } catch {
            try? files.removeItem(at: incoming)
            throw FlashError.tool("Couldn't copy the update into \(folder.path).")
        }
        do {
            try files.moveItem(at: installed, to: outgoing)
        } catch {
            try? files.removeItem(at: incoming)
            throw FlashError.tool("Couldn't move the installed app aside.")
        }
        do {
            try files.moveItem(at: incoming, to: installed)
        } catch {
            try? files.moveItem(at: outgoing, to: installed)
            try? files.removeItem(at: incoming)
            throw FlashError.tool("Couldn't put the update in place; the installed app is unchanged.")
        }
        try? files.removeItem(at: outgoing)
    }

    /// Opens `bundle` once this process has quit; the caller then quits.
    public static func relaunch(_ bundle: URL) throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch", String(ProcessInfo.processInfo.processIdentifier), bundle.path,
        ]
        do {
            try shell.run()
        } catch {
            throw FlashError.tool("Updated, but couldn't reopen it: quit and open it again.")
        }
    }
}
