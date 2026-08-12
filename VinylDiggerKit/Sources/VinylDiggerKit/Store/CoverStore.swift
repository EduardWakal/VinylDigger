import Foundation

/// Keeps sleeve images on disk so flipping back through the queue costs nothing.
public actor CoverStore {
    private let directory: URL
    private let transport: HTTPTransport

    public init(directory: URL, transport: HTTPTransport) {
        self.directory = directory
        self.transport = transport
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VinylDigger/Covers")
    }

    public func localURL(for releaseID: Int, remote: URL) async throws -> URL {
        let target = directory.appendingPathComponent("\(releaseID).jpg")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let (data, response) = try await transport.send(URLRequest(url: remote))
        guard (200..<300).contains(response.statusCode) else { throw DiscogsError.transport }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
        return target
    }
}
