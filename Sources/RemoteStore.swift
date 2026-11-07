import Foundation

/// التخزين البعيد (FTP على الـ FRITZ!Box)
protocol RemoteStore: AnyObject {
    func makeDir(_ path: String) async
    func size(_ path: String) async -> Int64?
    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func remove(_ path: String) async
    func move(_ from: String, to: String) async throws
    func listDirs(_ path: String) async throws -> [String]
    func close() async
}

enum Remote {
    static func open(_ cfg: NASConfig) async throws -> RemoteStore {
        let f = FTPClient(host: cfg.host.trimmingCharacters(in: .whitespaces))
        try await f.login(user: cfg.username, password: cfg.password)
        return FTPStore(f)
    }
}

final class FTPStore: RemoteStore {
    private let ftp: FTPClient
    init(_ ftp: FTPClient) { self.ftp = ftp }

    private func abs(_ p: String) -> String {
        "/" + p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func makeDir(_ path: String) async { await ftp.makeDir(abs(path)) }
    func size(_ path: String) async -> Int64? { await ftp.size(abs(path)) }
    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await ftp.upload(local, to: abs(path), progress: progress)
    }
    func remove(_ path: String) async { await ftp.delete(abs(path)) }
    func move(_ from: String, to: String) async throws { try await ftp.rename(abs(from), to: abs(to)) }
    func listDirs(_ path: String) async throws -> [String] { try await ftp.listDirectories(abs(path)) }
    func close() async { await ftp.quit() }
}
