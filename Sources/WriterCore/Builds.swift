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
    public let date: Date
    /// Built from the default branch (other branches publish prereleases).
    public let main: Bool
    public let zip: URL

    public init(id: Int, title: String, date: Date, main: Bool, zip: URL) {
        self.id = id
        self.title = title
        self.date = date
        self.main = main
        self.zip = zip
    }
}

public enum Builds {
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
                    date: release.published_at ?? release.created_at,
                    main: !release.prerelease,
                    zip: asset.browser_download_url)
            }
            .sorted { $0.date > $1.date }
    }

    /// The one chosen to begin with: the newest from the default branch.
    public static func preferred(_ builds: [Build]) -> Build? {
        builds.first(where: \.main) ?? builds.first
    }

    public static func list(repo: String) async throws -> [Build] {
        var request = URLRequest(url: listURL(repo: repo))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            return try parse(try await fetch(request))
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
