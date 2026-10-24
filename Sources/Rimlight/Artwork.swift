import Foundation
import ImageIO
import RimlightCore

/// Album-art colors for a Spotify track. The cover URL comes from the Spicetify extension when it runs, otherwise
/// from Spotify's public oEmbed endpoint for the track. Results are cached per track.
enum Artwork {
    private static var cache: [String: [RGB]] = [:]

    static func isMissing(_ uri: String) -> Bool { cache[uri] == nil }

    /// Calls `completion` on the main queue with three glow colors, or never if the cover can't be fetched.
    static func colors(for track: BridgeMessage.Track, completion: @escaping ([RGB]) -> Void) {
        if let c = cache[track.uri] { completion(c); return }
        let uri = track.uri
        imageURL(for: track) { url in
            guard let url else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let colors = palette(from: data) else { return }
                DispatchQueue.main.async {
                    cache[uri] = colors
                    completion(colors)
                }
            }.resume()
        }
    }

    private static func imageURL(for track: BridgeMessage.Track, _ done: @escaping (URL?) -> Void) {
        if let img = track.image {
            if img.hasPrefix("https://") { return done(URL(string: img)) }
            if img.hasPrefix("spotify:image:") {
                return done(URL(string: "https://i.scdn.co/image/" + img.dropFirst("spotify:image:".count)))
            }
        }
        let parts = track.uri.split(separator: ":")
        guard parts.count == 3, parts[1] == "track" || parts[1] == "episode",
              var q = URLComponents(string: "https://open.spotify.com/oembed") else { return done(nil) }
        q.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
        guard let url = q.url else { return done(nil) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done((json?["thumbnail_url"] as? String).flatMap(URL.init(string:)))
        }.resume()
    }

    /// Downsample to 48×48 RGBA and extract the palette.
    static func palette(from data: Data) -> [RGB]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96,
              ] as CFDictionary) else { return nil }
        let side = 48
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? Palette.extract(rgba: px) : nil
    }
}
