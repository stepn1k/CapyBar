import Foundation

/// A CapyBar version: the marketing version plus the build number from Info.plist.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let build: Int

    static let maxVersionLength = 32
    static let maxBuild = 1_000_000

    public init?(version: String, build: Int) {
        guard Self.isValidVersion(version), (0...Self.maxBuild).contains(build) else { return nil }
        self.version = version
        self.build = build
    }

    /// The running app's version, from its Info.plist. Nil outside an app bundle.
    public init?(infoDictionary info: [String: Any]?) {
        guard let version = info?["CFBundleShortVersionString"] as? String,
            let build = (info?["CFBundleVersion"] as? String).flatMap(Int.init)
        else { return nil }
        self.init(version: version, build: build)
    }

    /// One to four dot-separated numbers, like "0.2.0".
    static func isValidVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.utf8.count <= maxVersionLength else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    var numbers: [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }

    /// Higher version wins; with equal versions ("0.2" == "0.2.0"), the higher build.
    public func isNewer(than other: ReleaseInfo) -> Bool {
        let (a, b) = (numbers, other.numbers)
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return build > other.build
    }
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case http(Int)
    case badData

    public var errorDescription: String? {
        switch self {
        case .http(let status): "GitHub answered with HTTP \(status)."
        case .badData: "GitHub sent something that isn’t a CapyBar version."
        }
    }
}

/// Reads `version.json` from the rolling "latest" GitHub release, which CI publishes next
/// to CapyBar.zip (see scripts/bundle.sh --zip). One GET of a tiny file: no cookies, no
/// cache, nothing about the user or their apps is sent.
public enum UpdateCheck {
    public static let feedURL = URL(string: "https://github.com/stepn1k/CapyBar/releases/latest/download/version.json")!
    public static let downloadPageURL = URL(string: "https://github.com/stepn1k/CapyBar/releases/latest")!

    static let maxResponseSize = 4_096
    static let timeout: TimeInterval = 15

    private struct Payload: Decodable {
        let version: String
        let build: Int
    }

    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard data.count <= maxResponseSize,
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return ReleaseInfo(version: payload.version, build: payload.build)
    }

    public static func fetchLatest(from url: URL = feedURL) async throws -> ReleaseInfo {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        let (data, response) = try await session.data(for: request)
        // GitHub redirects release downloads to its asset host; insist it stays on HTTPS.
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw UpdateCheckError.badData
        }
        guard http.statusCode == 200 else { throw UpdateCheckError.http(http.statusCode) }
        guard let info = parse(data) else { throw UpdateCheckError.badData }
        return info
    }
}
