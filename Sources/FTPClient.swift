import Foundation
import Network

enum FTPError: LocalizedError {
    case connect(String)
    case reply(Int, String)
    case timeout
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .connect(let s): return "تعذّر الاتصال بخادم FTP: \(s)"
        case .reply(let c, let s):
            if c == 530 { return "اسم المستخدم أو كلمة المرور غير صحيحة." }
            if c == 550 { return "المجلد أو الملف غير موجود، أو لا توجد صلاحية." }
            return "رد الخادم \(c): \(s)"
        case .timeout: return "خادم FTP لم يرد في الوقت المحدد."
        case .protocolError(let s): return "خطأ FTP: \(s)"
        }
    }
}

/// عميل FTP بسيط (نمط Passive) يكفي للنسخ الاحتياطي إلى الـ FRITZ!Box
final class FTPClient {
    private let host: String
    private let port: UInt16
    private var ctrl: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "ftp.ctrl")
    private var timedOut = false

    init(host: String, port: UInt16 = 21) {
        self.host = host
        self.port = port
    }

    // MARK: - طبقة منخفضة

    private static func open(_ c: NWConnection, queue: DispatchQueue, timeout: Double = 10) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ r: Result<Void, Error>) {
                if finished { return }
                finished = true
                cont.resume(with: r)
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    finish(.success(()))
                case .failed(let e):
                    finish(.failure(FTPError.connect(e.localizedDescription)))
                case .waiting(let e):
                    if case .posix(let p) = e, p == .EPERM || p == .EACCES {
                        finish(.failure(FTPError.connect("الشبكة المحلية ممنوعة")))
                    }
                case .cancelled:
                    finish(.failure(FTPError.timeout))
                default:
                    break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !finished { c.cancel() }
            }
        }
    }

    private func receive(_ c: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let d = data, !d.isEmpty { cont.resume(returning: d); return }
                if isComplete { cont.resume(returning: nil); return }
                if let e = error {
                    // الخادم أغلق الاتصال بعد إرسال كل البيانات: iOS يبلّغ عنه بـ ENODATA (96) — هذه نهاية طبيعية
                    if case .posix(let code) = e, code == .ENODATA {
                        cont.resume(returning: nil); return
                    }
                    cont.resume(throwing: e); return
                }
                cont.resume(returning: Data())
            }
        }
    }

    private func sendData(_ c: NWConnection, _ d: Data?, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: d, contentContext: final ? .finalMessage : .defaultMessage, isComplete: final,
                   completion: .contentProcessed { e in
                       if let e = e { cont.resume(throwing: e) } else { cont.resume() }
                   })
        }
    }

    private func readLine(timeout: Double = 45) async throws -> String {
        while true {
            if let r = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard let c = ctrl else { throw FTPError.protocolError("غير متصل") }
            timedOut = false
            let watchdog = DispatchWorkItem { [weak self] in
                self?.timedOut = true
                c.cancel()
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let d: Data?
            do {
                d = try await receive(c)
            } catch {
                watchdog.cancel()
                if timedOut { throw FTPError.timeout }
                throw error
            }
            watchdog.cancel()
            guard let data = d else { throw FTPError.protocolError("انقطع الاتصال") }
            buffer.append(data)
        }
    }

    private func readReply() async throws -> (Int, String) {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw FTPError.protocolError(first)
        }
        var text = first
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let end = String(first.prefix(3)) + " "
            while true {
                let l = try await readLine()
                text += "\n" + l
                if l.hasPrefix(end) { break }
            }
        }
        return (code, text)
    }

    private func send(_ s: String) async throws {
        guard let c = ctrl else { throw FTPError.protocolError("غير متصل") }
        try await sendData(c, Data((s + "\r\n").utf8))
    }

    @discardableResult
    private func command(_ s: String, ok: ClosedRange<Int> = 200...399) async throws -> (Int, String) {
        try await send(s)
        let r = try await readReply()
        guard ok.contains(r.0) else { throw FTPError.reply(r.0, r.1) }
        return r
    }

    private static func parseEPSV(_ s: String) -> UInt16? {
        guard let a = s.range(of: "(|||"), let b = s.range(of: "|)", range: a.upperBound..<s.endIndex) else { return nil }
        return UInt16(s[a.upperBound..<b.lowerBound])
    }

    private static func parsePASV(_ s: String) -> UInt16? {
        guard let a = s.firstIndex(of: "("), let b = s.firstIndex(of: ")"), a < b else { return nil }
        let nums = s[s.index(after: a)..<b].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { return nil }
        return UInt16(nums[4] * 256 + nums[5])
    }

    private func openData() async throws -> NWConnection {
        var p: UInt16?
        if let r = try? await command("EPSV", ok: 229...229) { p = Self.parseEPSV(r.1) }
        if p == nil {
            let r = try await command("PASV", ok: 227...227)
            p = Self.parsePASV(r.1)
        }
        guard let port = p, let np = NWEndpoint.Port(rawValue: port) else {
            throw FTPError.protocolError("تعذّر فتح قناة البيانات")
        }
        let d = NWConnection(host: NWEndpoint.Host(host), port: np, using: .tcp)
        try await Self.open(d, queue: DispatchQueue(label: "ftp.data"))
        return d
    }

    // MARK: - الأوامر

    func login(user: String, password: String) async throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw FTPError.connect("منفذ غير صحيح") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        ctrl = c
        buffer = Data()
        try await Self.open(c, queue: queue)
        let hello = try await readReply()
        guard hello.0 == 220 else { throw FTPError.reply(hello.0, hello.1) }
        let u = try await command("USER \(user)", ok: 200...399)
        if u.0 == 331 { try await command("PASS \(password)", ok: 200...299) }
        _ = try? await command("OPTS UTF8 ON")
        try await command("TYPE I", ok: 200...299)
    }

    func makeDir(_ path: String) async {
        _ = try? await command("MKD \(path)", ok: 200...299)
    }

    func size(_ path: String) async -> Int64? {
        guard let r = try? await command("SIZE \(path)", ok: 213...213) else { return nil }
        return Int64(r.1.dropFirst(4).trimmingCharacters(in: .whitespaces))
    }

    func delete(_ path: String) async {
        _ = try? await command("DELE \(path)", ok: 200...299)
    }

    func rename(_ from: String, to: String) async throws {
        try await command("RNFR \(from)", ok: 350...350)
        try await command("RNTO \(to)", ok: 200...299)
    }

    func upload(_ local: URL, to path: String, progress: ((Int64) -> Void)? = nil) async throws {
        let data = try await openData()
        defer { data.cancel() }
        try await send("STOR \(path)")
        let pre = try await readReply()
        guard pre.0 == 125 || pre.0 == 150 else { throw FTPError.reply(pre.0, pre.1) }

        let fh = try FileHandle(forReadingFrom: local)
        defer { try? fh.close() }
        var sent: Int64 = 0
        while true {
            let chunk = try fh.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try await sendData(data, chunk)
            sent += Int64(chunk.count)
            progress?(sent)
        }
        try await sendData(data, nil, final: true)
        let done = try await readReply()
        guard (200...299).contains(done.0) else { throw FTPError.reply(done.0, done.1) }
    }

    private func listing(_ cmd: String) async throws -> String {
        let data = try await openData()
        defer { data.cancel() }
        try await send(cmd)
        let pre = try await readReply()
        guard pre.0 == 125 || pre.0 == 150 else { throw FTPError.reply(pre.0, pre.1) }
        var all = Data()
        while let d = try await receive(data) {
            all.append(d)
        }
        let done = try await readReply()
        guard (200...299).contains(done.0) else { throw FTPError.reply(done.0, done.1) }
        return String(decoding: all, as: UTF8.self)
    }

    func listDirectories(_ path: String) async throws -> [String] {
        if let text = try? await listing("MLSD \(path)") {
            return text.components(separatedBy: "\r\n").compactMap { line in
                guard let sp = line.firstIndex(of: " ") else { return nil }
                let facts = line[..<sp].lowercased()
                let name = String(line[line.index(after: sp)...])
                return facts.contains("type=dir;") ? name : nil
            }
        }
        let text = try await listing("LIST \(path)")
        return text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("d") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count == 9 else { return nil }
            let n = String(parts[8])
            return (n == "." || n == "..") ? nil : n
        }
    }

    func quit() async {
        _ = try? await command("QUIT")
        ctrl?.cancel()
        ctrl = nil
    }
}
