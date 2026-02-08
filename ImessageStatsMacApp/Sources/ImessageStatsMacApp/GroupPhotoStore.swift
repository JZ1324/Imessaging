import Foundation
import AppKit

final class GroupPhotoStore {
    static let shared = GroupPhotoStore()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "GroupPhotoStore", qos: .userInitiated)

    private init() {
        cache.countLimit = 150
    }

    func fetchImage(path: String, completion: @escaping (NSImage?) -> Void) {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        queue.async {
            guard let url = self.resolveURL(from: path) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = NSImage(contentsOf: url)
            if let image {
                self.cache.setObject(image, forKey: key)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func resolveURL(from path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return url
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }

        return nil
    }
}
