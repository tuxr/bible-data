import Foundation

enum DownloadError: Error, Equatable, CustomStringConvertible {
    case status(Int, url: URL)

    var description: String {
        switch self {
        case .status(let code, let url): "HTTP \(code) from \(url.absoluteString)"
        }
    }
}

enum HTTP {
    static let download: Download = { url in
        var request = URLRequest(url: url)
        request.setValue("bible-pack/\(BiblePackVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DownloadError.status(http.statusCode, url: url)
        }
        return data
    }
}
