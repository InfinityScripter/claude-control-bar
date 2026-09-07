import CryptoKit
import Foundation

/// The prebuilt half of a GitHub release: the DMG the one-click update installs, and the two
/// numbers that prove a download is the file the release advertised.
///
/// Releases are ad-hoc signed — there is no Developer ID to verify against — so integrity rests
/// on the size and the sha256 digest the releases API returns for each asset. Both come over
/// the same TLS connection as the download would, so this is not a defence against GitHub
/// itself; it is the check that a truncated, cached or swapped file never gets mounted.
enum UpdateFeed {
    struct ReleaseAsset: Equatable {
        let url: URL
        let size: Int
        /// Lowercase hex, without the `sha256:` prefix; nil when the release carries no digest
        /// (older releases, or a runner that uploaded without one).
        let sha256: String?

        /// The shape the daily check keeps in UserDefaults next to `latestVersion`.
        var dictionary: [String: Any] {
            var d: [String: Any] = ["url": url.absoluteString, "size": size]
            if let sha256 { d["sha256"] = sha256 }
            return d
        }

    }

    /// The first `.dmg` among a release's assets. A size-less entry is refused: the size is
    /// what tells a complete download from a cut-off one when no digest is advertised.
    static func dmgAsset(in release: [String: Any]) -> ReleaseAsset? {
        let assets = (release["assets"] as? [[String: Any]]) ?? []
        for a in assets {
            guard let name = a["name"] as? String, name.hasSuffix(".dmg"),
                  let s = a["browser_download_url"] as? String, let url = URL(string: s),
                  let size = (a["size"] as? NSNumber)?.intValue, size > 0 else { continue }
            let digest = (a["digest"] as? String) ?? ""
            let sha = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)).lowercased() : nil
            return ReleaseAsset(url: url, size: size, sha256: sha)
        }
        return nil
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// nil when the file is the asset; otherwise the reason it is not. Size first — one stat,
    /// and a mismatch there means the download is not worth reading, let alone hashing.
    static func verify(file: URL, against asset: ReleaseAsset) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        else { return "unreadable download" }
        if size != asset.size { return "size \(size), release says \(asset.size)" }
        if let want = asset.sha256 {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "unreadable download" }
            let got = sha256Hex(of: data)
            if got != want { return "sha256 \(got), release says \(want)" }
        }
        return nil
    }
}

extension UpdateFeed.ReleaseAsset {
    /// In an extension so the memberwise `init(url:size:sha256:)` stays synthesized.
    init?(dictionary d: [String: Any]) {
        guard let s = d["url"] as? String, !s.isEmpty, let url = URL(string: s),
              let size = (d["size"] as? NSNumber)?.intValue, size > 0 else { return nil }
        self.init(url: url, size: size, sha256: d["sha256"] as? String)
    }
}
