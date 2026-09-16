import CryptoKit
import Foundation
import Security

/// Everything about a private gateway's certificate: whether this Mac trusts it, how to obtain
/// the CA that signed it, and what has to change for each of the three programs that will talk
/// to the gateway.
///
/// The three do not agree, which is the whole reason this file exists. Measured on 2026-09-16
/// against a gateway whose CA was not installed:
///
/// | Consumer            | TLS stack           | Reads the macOS keychain |
/// |---------------------|---------------------|--------------------------|
/// | ClaudeSwitch        | URLSession          | yes                      |
/// | Claude Desktop      | Electron / Chromium | yes                      |
/// | Claude Code (CLI)   | Node v26            | **no**                   |
///
/// Node failed with `UNABLE_TO_VERIFY_LEAF_SIGNATURE` with the CA trusted in the login keychain,
/// and succeeded the moment `NODE_EXTRA_CA_CERTS` pointed at it. So trusting the CA in the
/// keychain fixes the desktop and this app while leaving the CLI broken — which is why
/// `NODE_EXTRA_CA_CERTS` is a managed key and not an afterthought.
public enum TLSTrust {
    // MARK: - Types

    /// What a human needs in order to decide whether to trust a certificate.
    public struct CertificateSummary: Hashable, Sendable {
        public var subject: String
        public var issuer: String
        public var notBefore: Date?
        public var notAfter: Date?
        /// Uppercase colon-separated SHA-256 of the DER, the form every tool prints.
        public var sha256: String

        public var isExpired: Bool {
            guard let notAfter else { return false }
            return notAfter < Date()
        }
    }

    public enum Status: Hashable, Sendable {
        /// The system verified the chain. Nothing to do, and nothing is shown.
        case trusted
        /// Reached, but the chain does not verify. Carries the leaf so the issuer can be named
        /// and a candidate anchor can be checked against it later.
        case untrusted(leaf: Data?, issuer: String?)
        /// Not an https URL, so there is no certificate to talk about.
        case notTLS
        case unreachable(String)
    }

    // MARK: - Checking

    /// Whether this Mac trusts `baseURL`'s certificate.
    ///
    /// The system decides, not this code: the request uses default handling, so an untrusted
    /// chain fails exactly as it would for any other app. The delegate's only job is to keep a
    /// copy of the leaf on the way past, so an untrusted result can still say who issued it.
    ///
    /// There is deliberately no "is this host internal?" heuristic anywhere. A handshake is
    /// ground truth, and a gateway with a public CA comes back `.trusted` and shows the user
    /// nothing at all.
    public static func check(baseURL: String, timeout: TimeInterval = 10) async -> Status {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(),
              url.host != nil
        else { return .unreachable("Base URL is not a valid URL.") }
        guard scheme == "https" else { return .notTLS }

        let collector = LeafCollector()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        // Any answer at all proves the handshake completed; the route and status do not matter.
        request.httpMethod = "HEAD"

        do {
            _ = try await session.data(for: request)
            return .trusted
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain, isTrustFailure(nsError.code) else {
                return .unreachable(HTTPClient.describe(error))
            }
            let leaf = collector.leaf
            return .untrusted(leaf: leaf, issuer: leaf.flatMap { issuerName(of: $0) })
        }
    }

    static func isTrustFailure(_ code: Int) -> Bool {
        [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
        ].contains(code)
    }

    /// Keeps the leaf certificate from a handshake without changing its outcome.
    private final class LeafCollector: NSObject, URLSessionDelegate {
        private let lock = NSLock()
        private var stored: Data?

        var leaf: Data? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                      URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust,
               let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let leaf = chain.first {
                lock.lock()
                stored = SecCertificateCopyData(leaf) as Data
                lock.unlock()
            }
            // The system's own verdict, unchanged. Never a credential, never a bypass.
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Obtaining a candidate anchor

    /// Paths tried on the gateway, in order, until one yields a certificate that verifies the
    /// leaf. There is no standard for this; these are the conventions seen in the wild.
    ///
    /// Trying several is safe rather than noisy only because of `anchor(_:verifies:)` below: a
    /// candidate that does not parse, or parses but did not sign this server's leaf, is dropped
    /// before the user is ever asked to confirm a fingerprint.
    public static let candidateAnchorPaths = ["ca.crt", "ca.pem", "ca-bundle.crt", "rootCA.crt"]

    /// Downloads a candidate anchor from the gateway.
    ///
    /// **This fetch cannot be verified, by definition** — we are asking the machine whose
    /// certificate we do not trust for the certificate that would make us trust it. A
    /// man-in-the-middle would serve its own CA and its own leaf, and the two would verify
    /// perfectly against each other.
    ///
    /// The only thing that makes the result trustworthy is a human comparing the fingerprint
    /// against a source that did not come down this connection. That is why `confirms(_:matches:)`
    /// requires the digits to be typed, and why this session is created here, used once, and
    /// never shared with API traffic. Do not "simplify" either of those.
    public static func fetchCandidateAnchor(baseURL: String, leaf: Data?,
                                            timeout: TimeInterval = 10) async -> Data? {
        guard let base = URL(string: baseURL) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let unverified = UnverifiedFetcher()
        let session = URLSession(configuration: config, delegate: unverified, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        for path in candidateAnchorPaths {
            guard let (data, _) = try? await session.data(from: base.appending(path: path))
            else { continue }
            for candidate in parseCertificates(from: data) {
                guard let leaf else { return candidate }
                if anchor(candidate, verifies: leaf) { return candidate }
            }
        }
        return nil
    }

    /// Accepts any server certificate, for the single unverifiable fetch above and nothing else.
    private final class UnverifiedFetcher: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                      URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    // MARK: - Parsing and validating

    /// Every certificate in `data`, as DER, whether it arrived as DER or as one or more PEM
    /// blocks with anything at all around them.
    public static func parseCertificates(from data: Data) -> [Data] {
        // A certificate is a DER SEQUENCE; anything starting that way is tried as-is first.
        if data.first == 0x30, SecCertificateCreateWithData(nil, data as CFData) != nil {
            return [data]
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let marker = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var out: [Data] = []
        for block in text.components(separatedBy: marker).dropFirst() {
            guard let body = block.components(separatedBy: end).first else { continue }
            let base64 = body.filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: base64),
                  SecCertificateCreateWithData(nil, der as CFData) != nil
            else { continue }
            out.append(der)
        }
        return out
    }

    /// Whether `candidate` is a usable trust anchor *for this server*.
    ///
    /// Three things have to hold, and SecTrust alone does not check all of them:
    ///
    /// 1. **It is not the leaf itself.** SecTrust trusts any certificate present in the anchor
    ///    list without further question, so passing the server's own certificate as its own
    ///    anchor evaluates clean. A server misconfigured to serve `server.crt` at `/ca.crt`
    ///    would otherwise sail through.
    /// 2. **It is marked as a CA.** Again not enforced for an anchor by SecTrust — but Node
    ///    *does* enforce it, and Node is what Claude Code runs on. Accepting a `CA:FALSE`
    ///    certificate here would leave this app and the desktop trusting a gateway that the CLI
    ///    still refuses, which is the exact failure this whole path exists to prevent.
    /// 3. **It signed this leaf**, and the chain is well formed and in date — which is what the
    ///    evaluation below establishes.
    ///
    /// Hostname is deliberately not checked: the real connection verifies that afterwards, and
    /// the leaf we hold came from that same connection.
    public static func anchor(_ candidate: Data, verifies leaf: Data) -> Bool {
        guard candidate != leaf, isCertificateAuthority(candidate) else { return false }
        guard let anchorCert = SecCertificateCreateWithData(nil, candidate as CFData),
              let leafCert = SecCertificateCreateWithData(nil, leaf as CFData)
        else { return false }

        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leafCert] as CFArray,
                                             SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust
        else { return false }

        guard SecTrustSetAnchorCertificates(trust, [anchorCert] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return false }

        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Whether the certificate carries `basicConstraints` with `CA:TRUE`.
    ///
    /// Read out of the DER directly. `SecCertificateCopyValues` renders this extension as
    /// display strings whose labels are localised, which is no basis for a security decision.
    /// The structure is fixed and small, so it is parsed rather than pattern-matched:
    ///
    ///     06 03 55 1D 13        OID 2.5.29.19 (basicConstraints)
    ///     [01 01 FF]            optional critical flag
    ///     04 <len>              OCTET STRING wrapping the extension value
    ///       30 <len>            SEQUENCE
    ///         [01 01 FF]        cA, absent or FALSE meaning not a CA
    public static func isCertificateAuthority(_ der: Data) -> Bool {
        let oid: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x13]
        let bytes = [UInt8](der)
        var index = 0
        while let found = firstRange(of: oid, in: bytes, from: index) {
            index = found + oid.count
            var cursor = index
            // An optional critical flag sits between the OID and the value.
            if cursor + 2 < bytes.count, bytes[cursor] == 0x01, bytes[cursor + 1] == 0x01 {
                cursor += 3
            }
            // The value is an OCTET STRING holding a SEQUENCE.
            guard cursor < bytes.count, bytes[cursor] == 0x04,
                  let octet = readLength(bytes, at: cursor + 1)
            else { continue }
            var inner = octet.valueStart
            guard inner < bytes.count, bytes[inner] == 0x30,
                  let sequence = readLength(bytes, at: inner + 1)
            else { continue }
            inner = sequence.valueStart
            // An empty SEQUENCE is cA = FALSE by omission.
            guard sequence.length >= 3, inner + 2 < bytes.count,
                  bytes[inner] == 0x01, bytes[inner + 1] == 0x01
            else { return false }
            return bytes[inner + 2] != 0x00
        }
        // No basicConstraints at all: not a CA.
        return false
    }

    /// A DER length, and where the value it measures begins.
    private static func readLength(_ bytes: [UInt8], at index: Int) -> (length: Int, valueStart: Int)? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        guard first & 0x80 != 0 else { return (Int(first), index + 1) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, index + count < bytes.count else { return nil }
        var length = 0
        for offset in 1 ... count { length = length << 8 | Int(bytes[index + offset]) }
        return (length, index + 1 + count)
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        for index in start ... (haystack.count - needle.count) {
            if Array(haystack[index ..< index + needle.count]) == needle { return index }
        }
        return nil
    }

    public static func summarize(_ der: Data) -> CertificateSummary {
        let cert = SecCertificateCreateWithData(nil, der as CFData)
        return CertificateSummary(
            subject: cert.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "unknown",
            issuer: cert.flatMap { commonName($0, oid: kSecOIDX509V1IssuerName) } ?? "unknown",
            notBefore: cert.flatMap { date($0, oid: kSecOIDX509V1ValidityNotBefore) },
            notAfter: cert.flatMap { date($0, oid: kSecOIDX509V1ValidityNotAfter) },
            sha256: fingerprint(der))
    }

    public static func issuerName(of der: Data) -> String? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return commonName(cert, oid: kSecOIDX509V1IssuerName)
    }

    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - The fingerprint gate

    /// The part of the fingerprint the user is asked to type. Four pairs is enough to make a
    /// real comparison happen without being so long that people give up and paste.
    public static func lastFourPairs(of fingerprint: String) -> String {
        String(hexDigits(fingerprint).suffix(8))
    }

    /// Whether what the user typed matches the end of `fingerprint`.
    ///
    /// A checkbox saying "I verified this" gets clicked past without being read. Typing the
    /// digits is the only version of this gate that requires the user to have actually looked at
    /// the other source — and that comparison is the sole reason a certificate fetched over an
    /// unverifiable connection can be trusted at all.
    public static func confirms(_ typed: String, matches fingerprint: String) -> Bool {
        let expected = lastFourPairs(of: fingerprint)
        guard expected.count == 8 else { return false }
        return hexDigits(typed) == expected
    }

    /// Hex digits only, uppercased — so colons, spaces, and dashes are all accepted.
    static func hexDigits(_ text: String) -> String {
        text.uppercased().filter(\.isHexDigit)
    }

    // MARK: - Where anchors live

    /// Where anchors are filed. A variable only so tests can point it at a temporary directory:
    /// installing into the real Application Support folder would make a test's result depend on
    /// whatever the person running it had already trusted. Production never sets it.
    public static var storageRoot = URL.applicationSupportDirectory
        .appending(path: "ClaudeSwitch", directoryHint: .isDirectory)

    public static var anchorDirectory: URL {
        storageRoot.appending(path: "anchors", directoryHint: .isDirectory)
    }

    /// The single file `NODE_EXTRA_CA_CERTS` points at. Node takes one path, so several gateways
    /// with several private CAs share one concatenated bundle.
    public static var bundlePath: URL {
        anchorDirectory.appending(path: "bundle.pem")
    }

    /// Filed under the fingerprint, so trusting the same CA twice is a no-op rather than a
    /// second copy.
    public static func anchorFilename(for summary: CertificateSummary) -> String {
        "\(hexDigits(summary.sha256).prefix(16)).crt"
    }

    /// The bundle: every anchor, ordered by filename so the file does not churn between
    /// rebuilds, each block newline-terminated so concatenation stays parseable.
    public static func bundleContents(from anchors: [String: String]) -> String {
        guard !anchors.isEmpty else { return "" }
        return anchors.sorted { $0.key < $1.key }
            .map { $0.value.hasSuffix("\n") ? $0.value : $0.value + "\n" }
            .joined()
    }

    // MARK: - What it does to the Mac

    /// Trust for SSL, in the user's own login keychain, and nothing more.
    ///
    /// Never `-d` (admin, every user) and never the System keychain: this is one person deciding
    /// to talk to one gateway, not a machine-wide policy. `security` raises the OS authorisation
    /// prompt itself, so the human confirms a second time in a dialog this app cannot forge.
    public static func addTrustCommand(anchorPath: String, loginKeychain: String) -> [String] {
        ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
         "-k", loginKeychain, anchorPath]
    }

    public static func removeTrustCommand(anchorPath: String) -> [String] {
        ["/usr/bin/security", "remove-trusted-cert", anchorPath]
    }

    public static var loginKeychainPath: String {
        URL.homeDirectory.appending(path: "Library/Keychains/login.keychain-db")
            .path(percentEncoded: false)
    }

    /// Runs `security`. Behind a protocol so tests can assert the command without a test ever
    /// touching a real keychain.
    public protocol CommandRunner: Sendable {
        /// The exit status, or a thrown error if the tool could not be launched at all.
        func run(_ arguments: [String]) throws -> Int32
    }

    public struct SystemCommandRunner: CommandRunner {
        public init() {}

        public func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(filePath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    /// What an install actually achieved. The two halves fail independently, and saying so
    /// precisely is the whole point — "it didn't work" would send the user back to guessing.
    public struct InstallOutcome: Hashable, Sendable {
        /// The anchor is on disk and `NODE_EXTRA_CA_CERTS` can be written: Claude Code will work.
        public var cliReady: Bool
        /// The CA is trusted in the login keychain: Claude Desktop and this app will work.
        public var keychainTrusted: Bool
        /// Set when the keychain half did not happen, in the user's terms.
        public var keychainMessage: String?
        public var fingerprint: String

        public var isComplete: Bool { cliReady && keychainTrusted }
    }

    /// Files the anchor, rebuilds the bundle, and offers it to the login keychain.
    ///
    /// The order matters: the CLI half needs no authorisation and cannot fail for permission
    /// reasons, so it happens first and survives the user cancelling the OS prompt.
    @discardableResult
    public static func install(anchor der: Data, trustInKeychain: Bool = true,
                               runner: CommandRunner = SystemCommandRunner()) throws -> InstallOutcome {
        let summary = summarize(der)
        let directory = anchorDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appending(path: anchorFilename(for: summary))
        try Data(pem(from: der).utf8).write(to: path, options: .atomic)
        try rebuildBundle()

        var outcome = InstallOutcome(cliReady: true, keychainTrusted: false,
                                     fingerprint: summary.sha256)
        guard trustInKeychain else { return outcome }

        let argv = addTrustCommand(anchorPath: path.path(percentEncoded: false),
                                   loginKeychain: loginKeychainPath)
        do {
            let status = try runner.run(argv)
            outcome.keychainTrusted = status == 0
            if status != 0 {
                // Cancelling the OS prompt lands here, and is not an error worth alarming about.
                outcome.keychainMessage =
                    "Not added to your login keychain — the authorisation prompt was declined or "
                    + "failed (status \(status)). Claude Code will still work; Claude Desktop will "
                    + "not until the CA is trusted."
            }
        } catch {
            outcome.keychainMessage = "Could not run security: \(error.localizedDescription)"
        }
        return outcome
    }

    /// Undoes `install`, so the app can remove a trust anchor from the same place it added one.
    @discardableResult
    public static func remove(fingerprint: String,
                              runner: CommandRunner = SystemCommandRunner()) throws -> Bool {
        let name = "\(hexDigits(fingerprint).prefix(16)).crt"
        let path = anchorDirectory.appending(path: name)
        var untrusted = true
        if FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) {
            untrusted = (try? runner.run(removeTrustCommand(anchorPath: path.path(percentEncoded: false)))) == 0
            try? FileManager.default.removeItem(at: path)
        }
        try rebuildBundle()
        return untrusted
    }

    /// Rewrites `bundle.pem` from whatever anchors remain, and removes it entirely when none do —
    /// so `NODE_EXTRA_CA_CERTS` never points at a file that is not there.
    public static func rebuildBundle() throws {
        let directory = anchorDirectory
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil)) ?? []
        var anchors: [String: String] = [:]
        for entry in entries where entry.pathExtension == "crt" {
            guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            anchors[entry.lastPathComponent] = text
        }
        let contents = bundleContents(from: anchors)
        if contents.isEmpty {
            try? manager.removeItem(at: bundlePath)
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: bundlePath, options: .atomic)
        }
    }

    /// Whether an anchor with this fingerprint is currently filed.
    public static func hasAnchor(fingerprint: String) -> Bool {
        let name = "\(hexDigits(fingerprint).prefix(16)).crt"
        return FileManager.default.fileExists(
            atPath: anchorDirectory.appending(path: name).path(percentEncoded: false))
    }

    /// DER as PEM, 64 characters to the line, which is what every tool expects to read.
    public static func pem(from der: Data) -> String {
        let body = der.base64EncodedString()
        var lines: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: 64, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[index ..< end]))
            index = end
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n")
            + "\n-----END CERTIFICATE-----\n"
    }

    // MARK: - Private

    /// Pulls a common name out of one of `SecCertificateCopyValues`' name sections.
    private static func commonName(_ cert: SecCertificate, oid: CFString) -> String? {
        guard let values = SecCertificateCopyValues(cert, [oid] as CFArray, nil) as? [String: Any],
              let section = values[oid as String] as? [String: Any],
              let entries = section[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return nil }
        // Prefer CN; fall back to the last labelled component, which is what tools display.
        var fallback: String?
        for entry in entries {
            guard let value = entry[kSecPropertyKeyValue as String] as? String else { continue }
            if entry[kSecPropertyKeyLabel as String] as? String == kSecOIDCommonName as String {
                return value
            }
            fallback = value
        }
        return fallback
    }

    private static func date(_ cert: SecCertificate, oid: CFString) -> Date? {
        guard let values = SecCertificateCopyValues(cert, [oid] as CFArray, nil) as? [String: Any],
              let section = values[oid as String] as? [String: Any],
              let interval = section[kSecPropertyKeyValue as String] as? Double
        else { return nil }
        // CSSM absolute time: seconds since 2001-01-01.
        return Date(timeIntervalSinceReferenceDate: interval)
    }
}
