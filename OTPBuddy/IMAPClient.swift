import Foundation

/// Minimal IMAP client using Network.framework-style blocking sockets via URLSession-less raw TCP is complex.
/// This implementation uses a simple POSIX socket IMAP subset (LOGIN, SELECT INBOX, SEARCH, FETCH BODY.PEEK).
/// Suitable for app-password / basic auth; OAuth2 XOAUTH2 can be added later on the same command path.
actor IMAPClient {
    struct Message: Sendable {
        let uid: UInt32
        let subject: String
        /// Plain text / MIME text part for reading in the UI.
        let body: String
        /// Headers + body used for OTP extraction.
        let scanText: String
        /// Server INTERNALDATE (or Date header fallback) when available.
        let receivedAt: Date?
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
                    let uids = try session.searchNewest(limit: limit)
                    var messages: [Message] = []
                    for uid in uids {
                        if let message = try session.fetchMessageForOTP(uid: uid) {
                            messages.append(message)
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
        case .invalidConfig: return String(localized: "Missing IMAP host or credentials")
        case .connectionFailed: return String(localized: "Could not connect to IMAP server")
        case .unexpectedResponse(let s): return String(localized: "Unexpected IMAP response: \(s)")
        case .authFailed: return String(localized: "IMAP authentication failed")
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

    /// Prefer recent UNSEEN mail. Never fall back to the whole mailbox — that re-scanned old
    /// messages and produced phantom OTPs from MIME/base64 digit noise.
    func searchNewest(limit: Int) throws -> [UInt32] {
        let since = Self.imapDate(Date().addingTimeInterval(-2 * 24 * 60 * 60))
        let unseenRecent = parseSearchUIDs(from: try command("UID SEARCH UNSEEN SINCE \(since)"))
        if !unseenRecent.isEmpty {
            return Array(unseenRecent.sorted().suffix(limit))
        }
        let unseen = parseSearchUIDs(from: try command("UID SEARCH UNSEEN"))
        if !unseen.isEmpty {
            return Array(unseen.sorted().suffix(limit))
        }
        let recent = parseSearchUIDs(from: try command("UID SEARCH RECENT"))
        return Array(recent.sorted().suffix(limit))
    }

    /// IMAP date token for SEARCH SINCE (day granularity).
    private static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    /// Subject + body text so codes in subjects like "812707 is your PIN code" are visible.
    func fetchMessageForOTP(uid: UInt32) throws -> IMAPClient.Message? {
        let meta = try command("UID FETCH \(uid) (INTERNALDATE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE)])")
        let text = try command("UID FETCH \(uid) (BODY.PEEK[TEXT])")
        let headerText = extractIMAPLiteral(from: meta)
        let bodyText = extractIMAPLiteral(from: text)
        let subject = parseHeaderField("Subject", from: headerText) ?? ""
        let scanText = (headerText + "\n" + bodyText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scanText.isEmpty else { return nil }
        let receivedAt = parseInternalDate(from: meta) ?? parseRFC822DateHeader(from: headerText)
        return IMAPClient.Message(
            uid: uid,
            subject: subject,
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            scanText: scanText,
            receivedAt: receivedAt
        )
    }

    private func parseHeaderField(_ name: String, from headers: String) -> String? {
        let pattern = "(?im)^\(NSRegularExpression.escapedPattern(for: name)):\\s*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..<headers.endIndex, in: headers)),
              let range = Range(match.range(at: 1), in: headers) else { return nil }
        return String(headers[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func close() {
        input?.close()
        output?.close()
    }

    /// Only parse UIDs from `* SEARCH …` lines — never tag numbers / timings in OK lines.
    private func parseSearchUIDs(from raw: String) -> [UInt32] {
        var uids: [UInt32] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("* SEARCH") else { continue }
            let payload = trimmed.dropFirst(8) // "* SEARCH"
            for token in payload.split(whereSeparator: { $0.isWhitespace }) {
                if let uid = UInt32(token) {
                    uids.append(uid)
                }
            }
        }
        return uids
    }

    /// IMAP INTERNALDATE: `12-Sep-2026 18:08:23 +0000`
    private func parseInternalDate(from response: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"INTERNALDATE "([^"]+)""#),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..<response.endIndex, in: response)),
              let range = Range(match.range(at: 1), in: response) else { return nil }
        let raw = String(response[range])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: raw)
    }

    private func parseRFC822DateHeader(from headers: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(?im)^Date:\s*(.+)$"#),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..<headers.endIndex, in: headers)),
              let range = Range(match.range(at: 1), in: headers) else { return nil }
        let raw = String(headers[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// Pull `{size}` literal payload(s) out of an IMAP FETCH response when present.
    private func extractIMAPLiteral(from response: String) -> String {
        guard let open = response.range(of: "{"),
              let close = response.range(of: "}", range: open.upperBound..<response.endIndex),
              let size = Int(response[open.upperBound..<close.lowerBound]),
              size > 0 else {
            return response
        }
        let start = close.upperBound
        guard let end = response.index(start, offsetBy: size, limitedBy: response.endIndex) else {
            return String(response[start...])
        }
        // Skip leading CRLF after `{n}`
        var payloadStart = start
        if response[payloadStart...].hasPrefix("\n") {
            payloadStart = response.index(after: payloadStart)
        } else if response[payloadStart...].hasPrefix("\r\n") {
            payloadStart = response.index(payloadStart, offsetBy: 2)
        }
        let payloadEnd = response.index(payloadStart, offsetBy: size, limitedBy: response.endIndex) ?? response.endIndex
        return String(response[payloadStart..<payloadEnd])
    }

    private func command(_ cmd: String) throws -> String {
        tag += 1
        let t = "A\(tag)"
        try write("\(t) \(cmd)\r\n")
        var collected = ""
        while true {
            let line = try readLine()
            collected += line + "\n"
            // Literals: `* … {123}` means the next `123` bytes are raw payload (may span lines).
            if let open = line.range(of: "{", options: .backwards),
               line.hasSuffix("}"),
               let size = Int(line[open.upperBound..<line.index(before: line.endIndex)]),
               size > 0 {
                collected += try readExact(size)
                collected += "\n"
            }
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

    private func readExact(_ count: Int) throws -> String {
        guard let input else { throw IMAPError.connectionFailed }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = input.read(&buffer[offset], maxLength: count - offset)
            if n <= 0 { break }
            offset += n
        }
        return String(bytes: buffer.prefix(offset), encoding: .utf8)
            ?? String(decoding: buffer.prefix(offset), as: UTF8.self)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
