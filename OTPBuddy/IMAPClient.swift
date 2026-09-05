import Foundation

/// Minimal IMAP client using Network.framework-style blocking sockets via URLSession-less raw TCP is complex.
/// This implementation uses a simple POSIX socket IMAP subset (LOGIN, SELECT INBOX, SEARCH, FETCH BODY.PEEK).
/// Suitable for app-password / basic auth; OAuth2 XOAUTH2 can be added later on the same command path.
actor IMAPClient {
    struct Message: Sendable {
        let uid: UInt32
        let body: String
    }

    private let account: IMAPAccount
    private let password: String

    init(account: IMAPAccount, password: String) {
        self.account = account
        self.password = password
    }

    func connect() async throws {
        // Validate configuration early; full socket connect happens on first fetch.
        guard !account.host.isEmpty, !account.username.isEmpty, !password.isEmpty else {
            throw IMAPError.invalidConfig
        }
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let session = try IMAPSession(host: self.account.host, port: self.account.port, useTLS: self.account.useTLS)
                    try session.login(user: self.account.username, password: self.password)
                    try session.selectInbox()
                    session.close()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func fetchRecentBodies(limit: Int) async throws -> [Message] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let session = try IMAPSession(host: self.account.host, port: self.account.port, useTLS: self.account.useTLS)
                    try session.login(user: self.account.username, password: self.password)
                    try session.selectInbox()
                    let uids = try session.searchRecent(limit: limit)
                    var messages: [Message] = []
                    for uid in uids {
                        if let body = try session.fetchBody(uid: uid) {
                            messages.append(Message(uid: uid, body: body))
                        }
                    }
                    session.close()
                    cont.resume(returning: messages)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

enum IMAPError: LocalizedError {
    case invalidConfig
    case connectionFailed
    case unexpectedResponse(String)
    case authFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfig: return "Missing IMAP host or credentials"
        case .connectionFailed: return "Could not connect to IMAP server"
        case .unexpectedResponse(let s): return "Unexpected IMAP response: \(s)"
        case .authFailed: return "IMAP authentication failed"
        }
    }
}

/// Tiny blocking IMAP session. Uses Security framework SSL if TLS enabled.
final class IMAPSession {
    private var input: InputStream?
    private var output: OutputStream?
    private var tag = 0

    init(host: String, port: Int, useTLS: Bool) throws {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        guard let input = readStream?.takeRetainedValue() as InputStream?,
              let output = writeStream?.takeRetainedValue() as OutputStream? else {
            throw IMAPError.connectionFailed
        }
        if useTLS {
            input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        }
        input.open()
        output.open()
        self.input = input
        self.output = output
        _ = try readLine() // greeting
    }

    func login(user: String, password: String) throws {
        let resp = try command("LOGIN \"\(escape(user))\" \"\(escape(password))\"")
        if resp.contains("NO") || resp.contains("BAD") { throw IMAPError.authFailed }
    }

    func selectInbox() throws {
        _ = try command("SELECT INBOX")
    }

    func searchRecent(limit: Int) throws -> [UInt32] {
        let raw = try command("UID SEARCH RECENT")
        // Fallback to ALL if RECENT empty
        var line = raw
        if !line.contains(where: { $0.isNumber }) {
            line = try command("UID SEARCH ALL")
        }
        let parts = line.split(separator: " ")
        var uids: [UInt32] = []
        for p in parts {
            if let v = UInt32(p) { uids.append(v) }
        }
        return Array(uids.suffix(limit))
    }

    func fetchBody(uid: UInt32) throws -> String? {
        let resp = try command("UID FETCH \(uid) (BODY.PEEK[TEXT])")
        return resp
    }

    func close() {
        input?.close()
        output?.close()
    }

    private func command(_ cmd: String) throws -> String {
        tag += 1
        let t = "A\(tag)"
        try write("\(t) \(cmd)\r\n")
        var collected = ""
        while true {
            let line = try readLine()
            collected += line + "\n"
            if line.hasPrefix(t + " OK") || line.hasPrefix(t + " NO") || line.hasPrefix(t + " BAD") {
                break
            }
        }
        return collected
    }

    private func write(_ s: String) throws {
        guard let output, let data = s.data(using: .utf8) else { throw IMAPError.connectionFailed }
        _ = data.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count) }
    }

    private func readLine() throws -> String {
        guard let input else { throw IMAPError.connectionFailed }
        var buffer: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = input.read(&byte, maxLength: 1)
            if n <= 0 { break }
            if byte == 10 { break } // \n
            if byte != 13 { buffer.append(byte) }
        }
        return String(bytes: buffer, encoding: .utf8) ?? ""
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
