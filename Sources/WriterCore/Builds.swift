import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One CI build of the config repo, published there as a GitHub release
/// with the firmware .zip attached (see the README for the workflow job).
public struct Build: Identifiable, Hashable, Sendable {
    public let id: Int
    /// The release's name: "<branch> · <commit subject>".
    public let title: String
    /// The config repo's CI run that built it, from the release's tag
    /// ("build-<number>"); nil for a tag of another shape.
    public let number: Int?
    public let date: Date
    /// Built from the default branch (other branches publish prereleases).
    public let main: Bool
    public let zip: URL
    /// The commit it was built from (the release's target), if known.
    public let commit: String?

    public init(id: Int, title: String, number: Int? = nil, date: Date, main: Bool, zip: URL, commit: String? = nil) {
        self.id = id
        self.title = title
        self.number = number
        self.date = date
        self.main = main
        self.zip = zip
        self.commit = commit
    }
}

extension Build {
    /// As the list of builds shows it: "203 · main · Subject".
    public var label: String {
        guard let number, title != "build-\(number)" else { return title }
        return "\(number) · \(title)"
    }
}

/// A commit in the config repo with a "settings-reset/<why>" tag: a build
/// that contains it wants a settings reset on each device that hasn't had
/// one for it yet.
public struct ResetTag: Hashable, Sendable {
    /// "settings-reset/dongle-central"
    public let name: String
    public let commit: String

    public init(name: String, commit: String) {
        self.name = name
        self.commit = commit
    }

    /// "dongle central" (empty for a bare "settings-reset/").
    public var why: String {
        String(name.dropFirst(Builds.resetTagPrefix.count))
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

public enum Builds {
    /// The number in a release tag "build-<number>", as the config repo's
    /// release job names them.
    public static func number(inTag tag: String) -> Int? {
        guard tag.hasPrefix("build-") else { return nil }
        return Int(tag.dropFirst("build-".count))
    }

    /// The config repo asked for when none is set, as "owner/name".
    public static let defaultRepo = "russwinch/zmk-config"

    public static func listURL(repo: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
    }

    /// The builds in GitHub's "list releases" answer, newest first. Drafts
    /// and releases with no .zip attached are left out.
    public static func parse(_ data: Data) throws -> [Build] {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let id: Int
            let name: String?
            let tag_name: String
            let target_commitish: String?
            let draft: Bool
            let prerelease: Bool
            let published_at: Date?
            let created_at: Date
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
            .compactMap { release -> Build? in
                guard !release.draft,
                    let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
                else { return nil }
                let name = release.name ?? ""
                return Build(
                    id: release.id,
                    title: name.isEmpty ? release.tag_name : name,
                    number: number(inTag: release.tag_name),
                    date: release.published_at ?? release.created_at,
                    main: !release.prerelease,
                    zip: asset.browser_download_url,
                    commit: release.target_commitish.flatMap(isCommit))
            }
            .sorted { $0.date > $1.date }
    }

    /// The builds the list offers: all of them, or only main's.
    public static func shown(_ builds: [Build], branches: Bool) -> [Build] {
        branches ? builds : builds.filter(\.main)
    }

    /// A full commit hash (a release's target can also be a branch name).
    static func isCommit(_ text: String) -> String? {
        text.count == 40 && text.allSatisfy(\.isHexDigit) ? text : nil
    }

    // MARK: Settings resets

    public static let resetTagPrefix = "settings-reset/"

    /// The repo's reset tags. Only lightweight tags (plain `git tag`) are
    /// read: an annotated one points at a tag object, not a commit.
    public static func parseResetTags(_ data: Data) throws -> [ResetTag] {
        struct Ref: Decodable {
            struct Object: Decodable {
                let sha: String
                let type: String
            }
            let ref: String
            let object: Object
        }
        return try JSONDecoder().decode([Ref].self, from: data).compactMap { ref in
            guard ref.object.type == "commit", ref.ref.hasPrefix("refs/tags/" + resetTagPrefix) else { return nil }
            return ResetTag(name: String(ref.ref.dropFirst("refs/tags/".count)), commit: ref.object.sha)
        }
    }

    public static func resetTags(repo: String) async throws -> [ResetTag] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/git/matching-refs/tags/\(resetTagPrefix)")!
        return try parseResetTags(try await fetch(request(url)))
    }

    /// From GitHub's "compare two commits" answer for base...head: is base
    /// part of head's history?
    public static func isAncestor(compared data: Data) throws -> Bool {
        struct Comparison: Decodable { let status: String }
        let status = try JSONDecoder().decode(Comparison.self, from: data).status
        return status == "ahead" || status == "identical"
    }

    /// Whether `build` (a commit) was built with `commit` in its history.
    public static func contains(_ commit: String, build: String, repo: String) async throws -> Bool {
        let url = URL(string: "https://api.github.com/repos/\(repo)/compare/\(commit)...\(build)?per_page=1")!
        return try isAncestor(compared: try await fetch(request(url)))
    }

    public static func list(repo: String) async throws -> [Build] {
        do {
            return try parse(try await fetch(request(listURL(repo: repo))))
        } catch is DecodingError {
            throw FlashError.tool("Couldn't read the list of builds from \(repo).")
        }
    }

    /// The build's .zip on this Mac, downloading it unless it is already here.
    public static func download(_ build: Build, into folder: URL? = nil) async throws -> URL {
        let folder = try folder ?? cacheFolder()
        let file = folder.appendingPathComponent("build-\(build.id).zip")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let data = try await fetch(URLRequest(url: build.zip))
        try data.write(to: file, options: .atomic)
        return file
    }

    static func cacheFolder() throws -> URL {
        let folder = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("keyboard-writer")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A GitHub API request.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Not needed for a public repo, but GitHub allows far more requests
        // an hour with one than without (CI's shared machines need that).
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// (URLSession's own async calls aren't in every Linux Foundation.)
    static func fetch(_ request: URLRequest) async throws -> Data {
        let host = request.url?.host ?? "the server"
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: FlashError.tool("Couldn't reach \(host): \(error.localizedDescription)"))
                } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    // 403 and 429 are GitHub's hourly limit for requests without a login.
                    let why = status == 403 || status == 429 ? "too many requests; try again later" : "error \(status)"
                    continuation.resume(throwing: FlashError.tool("\(host) said no (\(why))."))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }.resume()
        }
    }
}
