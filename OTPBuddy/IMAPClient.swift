import Foundation

/// Minimal IMAP client (LOGIN, SELECT INBOX, SEARCH, FETCH, IDLE).
/// Keeps one TLS session open; prefers IDLE for near-push delivery, with light polls as fallback.
actor IMAPClient {
    struct Message: Sendable {
        let uid: UInt32
        let subject: String
        /// Preferred display body (HTML when available).
        let body: String
        /// True when `body` is HTML (or HTML-ish) suitable for WKWebView.
        let isHTML: Bool
        /// Headers + text used for OTP extraction.
        let scanText: String
        /// Server INTERNALDATE (or Date header fallback) when available.
        let receivedAt: Date?
    }

    private let account: IMAPAccount
    private let password: String
    private let queue = DispatchQueue(label: "com.buddy.otp.imap")
    nonisolated(unsafe) private var session: IMAPSession?
    /// `nil` until probed; `false` means fall back to polling only.
    nonisolated(unsafe) private var idleSupported: Bool?

    init(account: IMAPAccount, password: String) {
        self.account = account
        self.password = password
    }

    func connect() async throws {
        guard !account.host.isEmpty, !account.username.isEmpty, !password.isEmpty else {
            throw IMAPError.invalidConfig
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.ensureSessionLocked()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func disconnect() {
        queue.async {
            self.session?.close()
            self.session = nil
            self.idleSupported = nil
        }
    }

    /// Abort a blocking IDLE/read so pause/stop can take effect immediately.
    func interrupt() {
        queue.async {
            self.session?.close()
            self.session = nil
        }
    }

    /// Blocks until the inbox may have new mail, IDLE is unsupported, or `timeout` elapses.
    /// Returns `true` when the server signaled a mailbox change.
    func idleForChanges(timeout: TimeInterval) async throws -> Bool {
        if idleSupported == false { return false }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let session = try self.ensureSessionLocked()
                    try session.ensureInboxSelected()
                    let result = try session.idle(timeoutSeconds: timeout)
                    switch result {
                    case .unsupported:
                        self.idleSupported = false
                        cont.resume(returning: false)
                    case .timedOut:
                        self.idleSupported = true
                        cont.resume(returning: false)
                    case .mailboxChanged:
                        self.idleSupported = true
                        cont.resume(returning: true)
                    }
                } catch {
                    self.session?.close()
                    self.session = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// `false` after the server rejects IDLE; otherwise try IDLE.
    func prefersIdle() -> Bool {
        idleSupported != false
    }

    /// Fetches only unknown UIDs. When `afterUID` is set, uses incremental `UID n:*` search.
    func fetchRecentBodies(
        limit: Int,
        excludingUIDs: Set<UInt32> = [],
        afterUID: UInt32 = 0
    ) async throws -> [Message] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let session = try self.ensureSessionLocked()
                    try session.ensureInboxSelected()
                    let uids = try session.searchNewest(limit: limit, afterUID: afterUID)
                        .filter { !excludingUIDs.contains($0) }
                    if !uids.isEmpty {
                        print("[OTP] fetch: \(uids.count) new uid(s) \(uids) afterUID=\(afterUID)")
                    }
                    var messages: [Message] = []
                    for uid in uids {
                        let fetchStarted = Date()
                        if let message = try session.fetchMessageForOTP(uid: uid) {
                            let ms = Date().timeIntervalSince(fetchStarted) * 1000
                            print(String(
                                format: "[OTP] fetched uid=%u subject=\"%@\" bytes~%d html=%@ in %.0fms",
                                uid,
                                String(message.subject.prefix(60)),
                                message.scanText.count,
                                message.isHTML ? "yes" : "no",
                                ms
                            ))
                            messages.append(message)
                        } else {
                            let ms = Date().timeIntervalSince(fetchStarted) * 1000
                            print(String(format: "[OTP] fetched uid=%u (empty/skip) in %.0fms", uid, ms))
                        }
                    }
                    cont.resume(returning: messages)
                } catch {
                    self.session?.close()
                    self.session = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func ensureSessionLocked() throws -> IMAPSession {
        if let session {
            return session
        }
        let session = try IMAPSession(host: account.host, port: account.port, useTLS: account.useTLS)
        try session.login(user: account.username, password: password)
        try session.selectInbox()
        self.session = session
        return session
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
    enum IdleResult {
        case mailboxChanged
        case timedOut
        case unsupported
    }

    private var input: InputStream?
    private var output: OutputStream?
    private var tag = 0
    private var inboxSelected = false

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
        inboxSelected = true
    }

    /// Cheap keepalive when already selected; full SELECT on first use / after reconnect.
    func ensureInboxSelected() throws {
        if inboxSelected {
            _ = try command("NOOP")
        } else {
            try selectInbox()
        }
    }

    /// Wait for EXISTS/RECENT (or timeout). Gmail-friendly max is ~29 minutes; callers should use less.
    func idle(timeoutSeconds: TimeInterval) throws -> IdleResult {
        tag += 1
        let t = "A\(tag)"
        try write("\(t) IDLE\r\n")

        let first = try readLine()
        let upperFirst = first.uppercased()
        if !first.hasPrefix("+") {
            if upperFirst.hasPrefix(t + " NO") || upperFirst.hasPrefix(t + " BAD") || upperFirst.hasPrefix(t) {
                return .unsupported
            }
            return .unsupported
        }

        let stateLock = NSLock()
        var doneSent = false
        let sendDone: () -> Void = {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !doneSent else { return }
            doneSent = true
            try? self.write("DONE\r\n")
        }

        let timeoutWork = DispatchWorkItem { sendDone() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + max(timeoutSeconds, 5),
            execute: timeoutWork
        )

        var changed = false
        while true {
            let line = try readLine()
            if line.isEmpty {
                timeoutWork.cancel()
                throw IMAPError.connectionFailed
            }
            let upper = line.uppercased()
            if upper.contains("EXISTS") || upper.contains("RECENT") {
                changed = true
                sendDone()
                continue
            }
            if line.hasPrefix(t + " OK") || line.hasPrefix(t + " NO") || line.hasPrefix(t + " BAD") {
                timeoutWork.cancel()
                return changed ? .mailboxChanged : .timedOut
            }
        }
    }

    /// Incremental when `afterUID` is known; otherwise UNSEEN + recent day (cold start).
    func searchNewest(limit: Int, afterUID: UInt32 = 0) throws -> [UInt32] {
        if afterUID > 0 {
            let incremental = parseSearchUIDs(from: try command("UID SEARCH UID \(afterUID + 1):*"))
                .filter { $0 > afterUID }
            if !incremental.isEmpty {
                return Array(incremental.sorted().suffix(limit))
            }
            // Catch messages another client marked Seen without advancing our high-water mark oddly.
            let unseen = parseSearchUIDs(from: try command("UID SEARCH UNSEEN"))
                .filter { $0 > afterUID }
            return Array(unseen.sorted().suffix(limit))
        }

        var uids = Set(parseSearchUIDs(from: try command("UID SEARCH UNSEEN")))
        let since = Self.imapDate(Date().addingTimeInterval(-24 * 60 * 60))
        let recentDay = parseSearchUIDs(from: try command("UID SEARCH SINCE \(since)"))
        for uid in recentDay.sorted().suffix(max(limit * 3, 12)) {
            uids.insert(uid)
        }
        if uids.isEmpty {
            let recent = parseSearchUIDs(from: try command("UID SEARCH RECENT"))
            uids.formUnion(recent)
        }
        return Array(uids.sorted().suffix(limit))
    }

    private static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    func fetchMessageForOTP(uid: UInt32) throws -> IMAPClient.Message? {
        let raw = try command(
            "UID FETCH \(uid) (INTERNALDATE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE)] BODY.PEEK[TEXT])"
        )
        let literals = extractIMAPLiterals(from: raw)
        let headerText = literals.first ?? ""
        let rawBody = literals.count > 1 ? literals[1] : (literals.first ?? "")
        let subject = parseHeaderField("Subject", from: headerText) ?? ""
        let parts = MIMEPartExtractor.extract(from: rawBody)
        let plain = parts.plain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let html = parts.html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayHTML: String?
        let displayPlain: String
        if !html.isEmpty {
            displayHTML = html
            // Flying Blue plain parts often embed huge CSS; prefer text from the HTML part.
            let plainLooksNoisy = (plain.contains("{") && plain.contains("}"))
                || plain.localizedCaseInsensitiveContains("multi-part message")
                || plain.count > 4_000
            displayPlain = (!plain.isEmpty && !plainLooksNoisy) ? plain : MIMEPartExtractor.stripTags(html)
        } else if MIMEPartExtractor.looksLikeHTML(fallback) {
            displayHTML = fallback
            displayPlain = MIMEPartExtractor.stripTags(fallback)
        } else {
            displayHTML = nil
            displayPlain = plain.isEmpty ? fallback : plain
        }

        let scanText = [headerText, subject, displayPlain, displayHTML.map(MIMEPartExtractor.stripTags) ?? ""]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scanText.isEmpty else { return nil }

        let receivedAt = parseInternalDate(from: raw) ?? parseRFC822DateHeader(from: headerText)
        return IMAPClient.Message(
            uid: uid,
            subject: subject,
            body: displayHTML ?? displayPlain,
            isHTML: displayHTML != nil,
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
        input = nil
        output = nil
        inboxSelected = false
    }

    private func parseSearchUIDs(from raw: String) -> [UInt32] {
        var uids: [UInt32] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("* SEARCH") else { continue }
            let payload = trimmed.dropFirst(8)
            for token in payload.split(whereSeparator: { $0.isWhitespace }) {
                if let uid = UInt32(token) {
                    uids.append(uid)
                }
            }
        }
        return uids
    }

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

    /// Pull leading `{size}` literal payloads from an IMAP FETCH response (header then body).
    /// Walks the response in order and stops after `maxCount` so braces inside the body are ignored.
    private func extractIMAPLiterals(from response: String, maxCount: Int = 2) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{(\d+)\}"#) else {
            return [stripIMAPTrailer(response)]
        }
        var literals: [String] = []
        var searchStart = response.startIndex
        while literals.count < maxCount, searchStart < response.endIndex {
            let space = NSRange(searchStart..<response.endIndex, in: response)
            guard let match = regex.firstMatch(in: response, range: space),
                  let sizeRange = Range(match.range(at: 1), in: response),
                  let size = Int(response[sizeRange]),
                  size > 0,
                  let tokenRange = Range(match.range, in: response) else {
                break
            }

            var payloadStart = tokenRange.upperBound
            if response[payloadStart...].hasPrefix("\r\n") {
                payloadStart = response.index(payloadStart, offsetBy: 2)
            } else if response[payloadStart...].hasPrefix("\n") {
                payloadStart = response.index(after: payloadStart)
            }
            let payloadEnd = response.index(payloadStart, offsetBy: size, limitedBy: response.endIndex) ?? response.endIndex
            literals.append(stripIMAPTrailer(String(response[payloadStart..<payloadEnd])))
            searchStart = payloadEnd
        }
        if literals.isEmpty {
            return [stripIMAPTrailer(response)]
        }
        return literals
    }

    private func stripIMAPTrailer(_ value: String) -> String {
        var text = value
        // Drop FETCH completion noise that sometimes leaks past the literal.
        if let regex = try? NSRegularExpression(pattern: #"\)?\s*A\d+\s+(?:OK|NO|BAD).*$"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func command(_ cmd: String) throws -> String {
        tag += 1
        let t = "A\(tag)"
        try write("\(t) \(cmd)\r\n")
        var collected = ""
        while true {
            let line = try readLine()
            collected += line + "\n"
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
            if byte == 10 { break }
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

/// Best-effort multipart extractor for common `multipart/alternative` OTP mail
/// (including Flying Blue / Air France bodies where the boundary is only in `--token` markers).
enum MIMEPartExtractor {
    static func extract(from raw: String) -> (plain: String?, html: String?) {
        let trimmed = stripIMAPTrailer(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return (nil, nil) }

        if let boundary = declaredBoundary(in: trimmed) ?? inferredBoundary(in: trimmed) {
            var plain: String?
            var html: String?
            let delimiter = "--\(boundary)"
            let parts = trimmed.components(separatedBy: delimiter)
            for part in parts {
                let normalized = normalizePart(part)
                let lower = normalized.lowercased()
                guard lower.contains("content-type:") else { continue }
                let payload = payload(afterHeadersIn: normalized)
                guard !payload.isEmpty else { continue }
                if lower.contains("content-type: text/html")
                    || lower.contains("content-type:text/html") {
                    html = decodeIfNeeded(payload, headers: normalized)
                } else if lower.contains("content-type: text/plain")
                            || lower.contains("content-type:text/plain") {
                    plain = decodeIfNeeded(payload, headers: normalized)
                }
            }
            if plain != nil || html != nil {
                return (plain, html)
            }
        }

        // No multipart markers — treat whole blob as HTML fragment or plain text.
        if looksLikeHTML(trimmed) { return (nil, trimmed) }
        return (trimmed, nil)
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") || lower.contains("<body") {
            return true
        }
        // Marketing mail often ships HTML fragments (tables/divs) without <html>.
        if lower.contains("<table") || lower.contains("<div") || lower.contains("<br") {
            return true
        }
        return false
    }

    static func stripTags(_ html: String) -> String {
        var text = html
        // Drop style/script blocks entirely so CSS never pollutes OTP scan/plain fallback.
        for pattern in [#"<(style|script)[^>]*>[\s\S]*?</\1>"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..<text.endIndex, in: text),
                    withTemplate: " "
                )
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: .dotMatchesLineSeparators) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: " "
            )
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func declaredBoundary(in raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)boundary="?([^"\s;]+)"?"#),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        return String(raw[range])
    }

    /// When BODY[TEXT] omits the multipart header, infer the boundary from repeated `--token` markers.
    private static func inferredBoundary(in raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"--([A-Za-z0-9'()+_,\-./:=?]+)"#) else {
            return nil
        }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var counts: [String: Int] = [:]
        for match in regex.matches(in: raw, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: raw) else { continue }
            var token = String(raw[range])
            if token.hasSuffix("--") {
                token = String(token.dropLast(2))
            }
            guard token.count >= 6 else { continue }
            counts[token, default: 0] += 1
        }
        return counts
            .filter { $0.value >= 2 }
            .max(by: { $0.value < $1.value })?
            .key
    }

    private static func normalizePart(_ part: String) -> String {
        var text = part
        if text.hasPrefix("--") {
            text = String(text.drop(while: { $0 == "-" }))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some servers flatten header separators; put Content-* fields on their own lines.
        if let regex = try? NSRegularExpression(pattern: #"\s+(Content-(?:Type|Transfer-Encoding|Disposition):)"#, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: "\n$1"
            )
        }
        return text
    }

    private static func payload(afterHeadersIn part: String) -> String {
        if let range = part.range(of: "\r\n\r\n") {
            return String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = part.range(of: "\n\n") {
            return String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Flattened headers: body starts after the last Content-* header value.
        if let regex = try? NSRegularExpression(
            pattern: #"(?is)Content-Transfer-Encoding:\s*[^\n]+[\n\r ]+"#,
            options: []
        ),
           let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..<part.endIndex, in: part)),
           let range = Range(match.range, in: part) {
            return String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let regex = try? NSRegularExpression(
            pattern: #"(?is)Content-Type:\s*[^\n]+(?:;[^\n]*)?[\n\r ]+"#,
            options: []
        ),
           let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..<part.endIndex, in: part)),
           let range = Range(match.range, in: part) {
            return String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return part.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripIMAPTrailer(_ value: String) -> String {
        var text = value
        if let regex = try? NSRegularExpression(pattern: #"\)?\s*A\d+\s+(?:OK|NO|BAD).*$"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeIfNeeded(_ payload: String, headers: String) -> String {
        let lower = headers.lowercased()
        let cleanedPayload = stripIMAPTrailer(payload)
        if lower.contains("content-transfer-encoding: base64") {
            let cleaned = cleanedPayload
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            if let data = Data(base64Encoded: cleaned),
               let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
        }
        if lower.contains("content-transfer-encoding: quoted-printable") {
            return decodeQuotedPrintable(cleanedPayload)
        }
        return cleanedPayload
    }

    private static func decodeQuotedPrintable(_ input: String) -> String {
        var output = Data()
        let bytes = Array(input.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == 10 || bytes[i + 1] == 13 {
                    i += 1
                    if i < bytes.count, bytes[i] == 13 { i += 1 }
                    if i < bytes.count, bytes[i] == 10 { i += 1 }
                    continue
                }
                if i + 2 < bytes.count,
                   let hi = hexValue(bytes[i + 1]),
                   let lo = hexValue(bytes[i + 2]) {
                    output.append(hi * 16 + lo)
                    i += 3
                    continue
                }
            }
            if b != 13 {
                output.append(b)
            }
            i += 1
        }
        return String(data: output, encoding: .utf8)
            ?? String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
