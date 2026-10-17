import AppKit
import WheelCore

/// Steam library cover art (600×900) for a game: from Steam's own local cache when the game is in
/// the user's Steam library, otherwise downloaded once from Steam's CDN and kept in
/// ~/Library/Caches/crossover-ffb/artwork. Nothing is bundled with the app.
enum GameArtwork {
    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("crossover-ffb/artwork")

    /// Blocking; call off the main thread.
    static func cover(appID: Int) -> NSImage? {
        if let url = localSteamCover(appID: appID), let image = NSImage(contentsOf: url) { return image }
        let cached = cacheDirectory.appendingPathComponent("\(appID).jpg")
        if let image = NSImage(contentsOf: cached) { return image }
        for name in ["library_600x900_2x.jpg", "library_600x900.jpg", "header.jpg"] {
            guard let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(name)"),
                  let data = download(url), let image = NSImage(data: data) else { continue }
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cached, options: .atomic)
            return image
        }
        return nil
    }

    /// Steam (macOS) keeps library art in appcache/librarycache/<appid>/…/library_600x900.jpg
    /// (older clients: librarycache/<appid>_library_600x900.jpg).
    static func localSteamCover(appID: Int) -> URL? {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/appcache/librarycache")
        let flat = cache.appendingPathComponent("\(appID)_library_600x900.jpg")
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        let folder = cache.appendingPathComponent("\(appID)")
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        var fallback: URL?
        for case let url as URL in walker {
            switch url.lastPathComponent {
            case "library_600x900_2x.jpg": return url
            case "library_600x900.jpg": fallback = url
            default: break
            }
        }
        return fallback
    }

    private static func download(_ url: URL) -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data, !data.isEmpty { result = data }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
