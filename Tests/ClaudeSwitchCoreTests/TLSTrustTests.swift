import Foundation
import Testing
@testable import ClaudeSwitchCore

/// Synthetic certificates, generated for these tests only — a CA, a leaf it signed, and an
/// unrelated CA. Deliberately not the real gateway's: a public repository is no place for
/// internal host names, and the parsing and chain logic does not care whose bytes they are.
enum TrustFixtures {
    static let ca = """
    -----BEGIN CERTIFICATE-----
    MIIDETCCAfmgAwIBAgIJAJ4zoTUQUr8lMA0GCSqGSIb3DQEBCwUAMDwxHTAbBgNV
    BAMMFENsYXVkZVN3aXRjaCBUZXN0IENBMRswGQYDVQQKDBJDbGF1ZGVTd2l0Y2gg
    VGVzdHMwHhcNMjYwOTE2MTg1ODM2WhcNNDYwOTExMTg1ODM2WjA8MR0wGwYDVQQD
    DBRDbGF1ZGVTd2l0Y2ggVGVzdCBDQTEbMBkGA1UECgwSQ2xhdWRlU3dpdGNoIFRl
    c3RzMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqHENHZ3MK3hxcvON
    ow8gaG31eMWi0sjfA0d8wGoK2aSJ5/tz4KmKZhLWtb4ZVaIa7WbJhfFT+kylO2Oz
    fW1vgV3jh7rdJEualGV7WION3qi4jyPOGmFkzLC9lURrR5l12KsdgM7DfA7VyJ7j
    9Q/wHdkEyJgDd2177ma4lOmMdGDnQ4dm/FpdJz5MSzitbl/coJtH3Tp99h/PKmPS
    qbWrgZEKyo2folBj9t2iT0sZ32nuD/4655JhhgD8v3QJJ1AQmGYTdDE78jF5bktG
    5hyjsQvMHGAedyWCOz2iHCLBL3N39S9BUVw6hAINkdSL4zzcJdmgUWKL6WfuduCq
    jBDiLwIDAQABoxYwFDASBgNVHRMBAf8ECDAGAQH/AgEAMA0GCSqGSIb3DQEBCwUA
    A4IBAQA6eJ6cY1Y+AD2GDpL0/iMa97GJgNdjwZ8WsD4ccvAWiJZPAbAKNdqJN4Mq
    f+c+YEWIsgW+Ahh9rG4t4cyYPYMLDBJwiKf4/y4Zw+GtmdgIUJV0wTLPrhTP9/0j
    59JdAB7z/7t+uvowHNzbcBMpbRl/bJHE2xHqmxhTZveP5k2FxrqWWcLl0RqTd2MR
    WEOs5txcUZUg8JAoEZorMerTNVPRzRjLjH27tag9w5LHd62lNhpzqsbB1Mc2/WXg
    VQvCZWfQkE20ONnkcrYNYOA9DASy4VT1XyiefUeOCbVJIcEbSuEX/AXoN6Hfpcsj
    diZ4zvu6ZcYxcGssNESLCGLf5iRk
    -----END CERTIFICATE-----
    """

    static let leaf = """
    -----BEGIN CERTIFICATE-----
    MIIDHDCCAgSgAwIBAgIJALyJ4RggkPeZMA0GCSqGSIb3DQEBCwUAMDwxHTAbBgNV
    BAMMFENsYXVkZVN3aXRjaCBUZXN0IENBMRswGQYDVQQKDBJDbGF1ZGVTd2l0Y2gg
    VGVzdHMwHhcNMjYwOTE2MTg1ODM2WhcNNDYwOTExMTg1ODM2WjA0MRUwEwYDVQQD
    DAxnYXRld2F5LnRlc3QxGzAZBgNVBAoMEkNsYXVkZVN3aXRjaCBUZXN0czCCASIw
    DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANYfF18keFl81qYuhOWp11e7nbUc
    DBVdKWQiBTcAmXAUpZ/IKPnIwZGCAzbCl45mzFJfvSSvpPoRQRgItyrgCJ0bU4DW
    AakZuyv7LVUyIWrWSEG4oLzIzsvgmo74oL6Az3wEtofFpt2HB853hWOwG5RWVCl0
    66IKS1PDgXsgtDoAjhP3pDMZDoG4M32BiDSGH0ntTheD/TyBO5QpDEE/f0d+S356
    /n/WnR8K39kTNuGzCHij0pTZaWbmdeup43PxwWNGjmkbQmKIolkbltUQS0i6nJ7a
    T/nyCSBRZ3MCLf/BMORp1FSVi9Uz8ViOt/aApB7rqXrK4ayktiogMCzlqakCAwEA
    AaMpMCcwFwYDVR0RBBAwDoIMZ2F0ZXdheS50ZXN0MAwGA1UdEwEB/wQCMAAwDQYJ
    KoZIhvcNAQELBQADggEBAAl9rDS5CW0xDOvEbSqZQlfHBIoHCDQQREZgOe9zUZPA
    Kdi0dPvBTP1stYDmSsNb4zmjW7vxRdd2549Okfh4YISUJvHrOdPee1Kd5ZfkDzfC
    M0UEHiPvBtUw5ntCxAD93lXoeJeEwUQJqZSwlUhpoKfWrNv4YjslKmAh5AuZmdIF
    uM7l7bvOol9PZjWEnxUxCSBhB6A+Rmg0Yt3mciZo7j7CvshB0FW3GJq4y3T1kEjf
    89Lh40ZQ7xsg3vKqKG8QmBQorijYYeqikRzJNT3HEDTz/5wC/ipAOfnSn5mOOGrw
    x+19AxHeeczv65TiUZrfAie0Gf76YHNTP74SIZoY3Wc=
    -----END CERTIFICATE-----
    """

    static let unrelatedCA = """
    -----BEGIN CERTIFICATE-----
    MIIDCDCCAfCgAwIBAgIJAOUosWH9KELuMA0GCSqGSIb3DQEBCwUAMDkxGjAYBgNV
    BAMMEVVucmVsYXRlZCBUZXN0IENBMRswGQYDVQQKDBJDbGF1ZGVTd2l0Y2ggVGVz
    dHMwHhcNMjYwOTE2MTg1ODM2WhcNNDYwOTExMTg1ODM2WjA5MRowGAYDVQQDDBFV
    bnJlbGF0ZWQgVGVzdCBDQTEbMBkGA1UECgwSQ2xhdWRlU3dpdGNoIFRlc3RzMIIB
    IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuiZNTcZsEoUIY3u/9aggvyeB
    zm8s2456qNSphwhjezz/maQDw4Zn1gAoujfxVacz8oxYJHowAb0Z4xI/KMk0854s
    F2JPc4kGHCBE6PBiGsfvhFFbvnITgXBWDncYAX7AaiWAjaCFel5G/A7L9kGaasgN
    fSucxwAgcRdcfkRDaVPJcokcFNYhz1L2nw0eu6DiJBmEJAEo8xoUs8MQ/x75dvi9
    HL1nf5tPQyMZMh1SBL8hhDl6a0wkxVx2hgaP5uriVy+8m4QJEhXEmFH61CLpwKWH
    XSFHEe1tzd9Pz+uBUc0QBLE4mMgmbx5qVcoENkIfp35rZfezJrsOvSPKBMLyQwID
    AQABoxMwETAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQC3QkOf
    mMa/RkcI3GHL+bvZgPStif6LCitDY5U/YulLKm8fsfB9ZGDKOqmLR4zexm0LMCoW
    Dz+UL4L5d2d962790NAGIJZoi9KCg2MzFL6NA5rNVipsQAWZUxjwCM4rp6WmumaV
    eGLLyKPSqYsMY+XUoclqNgCClj2kmSILBXk5XojhLE+f2qeakHVBUDelMkvQg5dR
    UYdLMH2J1HRk4LO6lwX+xjFjrJ2LQdfDwthLvKGRYNvmNIO+wovlHmUf+UgrtdmJ
    Fcr08dh62qnyh4GhSwdPB2RY+8VcZKVU5LMGLIRESxrKtn3Z+rEcCSIOqxJBfqWq
    qjMXukpFR6OL+3nt
    -----END CERTIFICATE-----
    """
}

@Suite("TLS trust: certificates")
struct TLSTrustCertificateTests {
    @Test("Reads a PEM block, and a DER body, to the same certificate")
    func parsesPEMAndDER() throws {
        let fromPEM = TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8))
        #expect(fromPEM.count == 1)

        let der = try #require(fromPEM.first)
        // A certificate is a DER SEQUENCE, so the raw body is recognised without any armour.
        #expect(der.first == 0x30)
        #expect(TLSTrust.parseCertificates(from: der) == [der])
    }

    @Test("Reads every block of a concatenated bundle, and ignores text around them")
    func parsesBundle() {
        let bundle = "# issued 2026\n" + TrustFixtures.ca + "\n\ntrailing notes\n" + TrustFixtures.unrelatedCA
        #expect(TLSTrust.parseCertificates(from: Data(bundle.utf8)).count == 2)
    }

    @Test("Refuses anything that is not a certificate")
    func refusesGarbage() {
        #expect(TLSTrust.parseCertificates(from: Data("not a certificate".utf8)).isEmpty)
        #expect(TLSTrust.parseCertificates(from: Data()).isEmpty)
        // Correct armour, base64 that decodes to nothing a certificate could be.
        let fake = "-----BEGIN CERTIFICATE-----\naGVsbG8=\n-----END CERTIFICATE-----"
        #expect(TLSTrust.parseCertificates(from: Data(fake.utf8)).isEmpty)
    }

    @Test("A candidate anchor is accepted only when it signed the leaf we actually saw")
    func anchorMustSignTheLeaf() throws {
        let ca = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
        let leaf = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.leaf.utf8)).first)
        let other = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.unrelatedCA.utf8)).first)

        #expect(TLSTrust.anchor(ca, verifies: leaf))
        // The whole point of the check: a real CA that is simply not this server's is refused,
        // so a wrong file fetched from the gateway never reaches the fingerprint gate.
        #expect(!TLSTrust.anchor(other, verifies: leaf))
    }

    /// A server misconfigured to serve its own `server.crt` at `/ca.crt`. SecTrust alone accepts
    /// this — anything in the anchor list is trusted without a CA check — so this case is guarded
    /// explicitly. Node enforces CA:TRUE, so letting it through would leave ClaudeSwitch and the
    /// desktop green while Claude Code kept refusing the gateway.
    @Test("A server certificate offered as its own anchor is refused")
    func leafIsNotItsOwnAnchor() throws {
        let leaf = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.leaf.utf8)).first)
        #expect(!TLSTrust.anchor(leaf, verifies: leaf))
    }

    @Test("Reads CA:TRUE out of basicConstraints, and its absence")
    func basicConstraints() throws {
        let ca = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
        let leaf = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.leaf.utf8)).first)
        let other = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.unrelatedCA.utf8)).first)

        #expect(TLSTrust.isCertificateAuthority(ca))       // CA:TRUE, pathlen:0
        #expect(TLSTrust.isCertificateAuthority(other))    // CA:TRUE, no pathlen
        #expect(!TLSTrust.isCertificateAuthority(leaf))    // CA:FALSE
        #expect(!TLSTrust.isCertificateAuthority(Data()))
    }

    @Test("Summarises a certificate for the human deciding whether to trust it")
    func summary() throws {
        let ca = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
        let summary = TLSTrust.summarize(ca)
        #expect(summary.subject.contains("ClaudeSwitch Test CA"))
        #expect(summary.issuer.contains("ClaudeSwitch Test CA"))
        #expect(summary.notAfter != nil)
        // 32 bytes as uppercase pairs.
        #expect(summary.sha256.split(separator: ":").count == 32)
        #expect(summary.sha256 == summary.sha256.uppercased())
    }
}

@Suite("TLS trust: the fingerprint gate")
struct TLSTrustFingerprintTests {
    static let fingerprint = "CB:C4:D1:D4:86:9E:18:25:12:B4:16:4B:5E:EA:D5:AA:34:0A:A1:41:81:6D:1F:98:99:56:1E:05:04:D0:62:26"

    @Test("Asks for the last four pairs")
    func lastFourPairs() {
        #expect(TLSTrust.lastFourPairs(of: Self.fingerprint) == "04D06226")
    }

    @Test("Accepts what a human would plausibly type")
    func acceptsHumanInput() {
        for typed in ["04D06226", "04d06226", "04:D0:62:26", " 04 d0 62 26 ", "04-d0-62-26"] {
            #expect(TLSTrust.confirms(typed, matches: Self.fingerprint),
                    "should accept \(typed.debugDescription)")
        }
    }

    @Test("Refuses a near miss, and refuses emptiness")
    func refusesWrongInput() {
        // Transposed, one digit off, too short, the wrong end of the fingerprint, nothing.
        for typed in ["04D06622", "04D06227", "D06226", "CBC4D1D4", "", "   "] {
            #expect(!TLSTrust.confirms(typed, matches: Self.fingerprint),
                    "should refuse \(typed.debugDescription)")
        }
    }
}

@Suite("TLS trust: what it does to the Mac")
struct TLSTrustInstallTests {
    @Test("Trusts for SSL, in the login keychain, and nowhere else")
    func addCommand() {
        let argv = TLSTrust.addTrustCommand(anchorPath: "/tmp/a.crt",
                                            loginKeychain: "/Users/x/Library/Keychains/login.keychain-db")
        #expect(argv == ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
                         "-k", "/Users/x/Library/Keychains/login.keychain-db", "/tmp/a.crt"])
        // The two escalations this must never make: admin/system-wide, and the System keychain.
        #expect(!argv.contains("-d"))
        #expect(!argv.joined(separator: " ").contains("/Library/Keychains/System.keychain"))
    }

    @Test("Removing trust undoes exactly what was added")
    func removeCommand() {
        #expect(TLSTrust.removeTrustCommand(anchorPath: "/tmp/a.crt")
                == ["/usr/bin/security", "remove-trusted-cert", "/tmp/a.crt"])
    }

    @Test("The bundle is every anchor, in a stable order, each properly terminated")
    func bundleContents() {
        let bundle = TLSTrust.bundleContents(from: ["b": TrustFixtures.unrelatedCA,
                                                    "a": TrustFixtures.ca])
        // Sorted by filename so the file does not churn between rebuilds.
        #expect(bundle.hasPrefix(TrustFixtures.ca))
        #expect(bundle.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 3)
        #expect(bundle.hasSuffix("\n"))
        #expect(TLSTrust.parseCertificates(from: Data(bundle.utf8)).count == 2)
    }

    @Test("No anchors means no bundle, so the env key can be dropped rather than left dangling")
    func emptyBundle() {
        #expect(TLSTrust.bundleContents(from: [:]).isEmpty)
    }

    @Test("An anchor is filed under its own fingerprint, so the same CA is never stored twice")
    func anchorFilename() throws {
        let ca = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
        let name = TLSTrust.anchorFilename(for: TLSTrust.summarize(ca))
        #expect(name.hasSuffix(".crt"))
        #expect(!name.contains(":"))
        #expect(!name.contains("/"))
        let again = TLSTrust.anchorFilename(for: TLSTrust.summarize(ca))
        #expect(name == again)
    }

    @Test("Candidate URLs are tried on the gateway itself, and are all plain paths")
    func candidatePaths() {
        #expect(TLSTrust.candidateAnchorPaths.first == "ca.crt")
        #expect(TLSTrust.candidateAnchorPaths.count <= 4)
        for path in TLSTrust.candidateAnchorPaths {
            #expect(!path.hasPrefix("/"))
            #expect(!path.contains(".."))
        }
    }
}

/// Records what would have been run. No test may touch a real keychain.
final class FakeRunner: TLSTrust.CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let status: Int32

    init(status: Int32 = 0) { self.status = status }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String]) throws -> Int32 {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        return status
    }
}

/// Both of these suites move `TLSTrust.storageRoot`, which is process-wide, so they are nested
/// inside one `.serialized` suite: `.serialized` orders a suite's own tests and its sub-suites,
/// and without the nesting the two would run in parallel and each would be building its bundle
/// in the other's directory.
@Suite("TLS trust: anchors on disk", .serialized)
struct TLSTrustStorageTests {
    /// Installs into a temporary directory, never the real Application Support folder — otherwise a
    /// CA the person running the tests had already trusted would change the results.
    /// `.serialized` because the storage root is process-wide.
    @Suite("installing and undoing", .serialized)
    struct InstallingAndUndoing {
        init() {
            TLSTrust.storageRoot = URL(filePath: NSTemporaryDirectory())
                .appending(path: "ClaudeSwitchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            // Same reason as the storage root: the real resolver reads the tester's own
            // settings.json, and a corporate NODE_EXTRA_CA_CERTS there would put extra
            // certificates in the bundle these tests count.
            TLSTrust.foreignBundlePathResolver = { nil }
        }

        @Test("PEM round-trips back to the same certificate, wrapped at 64 columns")
        func pemRoundTrip() throws {
            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let pem = TLSTrust.pem(from: der)
            #expect(TLSTrust.parseCertificates(from: Data(pem.utf8)) == [der])
            let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }
            #expect(body.allSatisfy { $0.count <= 64 })
        }

        @Test("A declined authorisation prompt still leaves Claude Code working, and says so")
        func keychainDeclined() throws {
            let runner = FakeRunner(status: 1)
            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let outcome = try TLSTrust.install(anchor: der, runner: runner)
            defer { try? TLSTrust.remove(fingerprint: outcome.fingerprint, runner: FakeRunner()) }

            // The half that needs no authorisation happened anyway — that is the point of the order.
            #expect(outcome.cliReady)
            #expect(!outcome.keychainTrusted)
            #expect(!outcome.isComplete)
            #expect(outcome.keychainMessage?.contains("Claude Code will still work") == true)
        }

        @Test("A successful install files the anchor, builds the bundle, and trusts it once")
        func installSucceeds() throws {
            let runner = FakeRunner()
            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let outcome = try TLSTrust.install(anchor: der, runner: runner)

            #expect(outcome.isComplete)
            #expect(TLSTrust.hasAnchor(fingerprint: outcome.fingerprint))
            #expect(FileManager.default.fileExists(
                atPath: TLSTrust.bundlePath.path(percentEncoded: false)))
            // Exactly one keychain command, and it is the narrowly scoped one.
            #expect(runner.commands.count == 1)
            #expect(runner.commands.first?.contains("add-trusted-cert") == true)
            #expect(runner.commands.first?.contains("-d") == false)

            // Undo leaves nothing behind, so NODE_EXTRA_CA_CERTS never points at a missing file.
            let remover = FakeRunner()
            _ = try TLSTrust.remove(fingerprint: outcome.fingerprint, runner: remover)
            #expect(!TLSTrust.hasAnchor(fingerprint: outcome.fingerprint))
            #expect(remover.commands.first?.contains("remove-trusted-cert") == true)
            #expect(!FileManager.default.fileExists(
                atPath: TLSTrust.bundlePath.path(percentEncoded: false)))
        }

        @Test("Trusting the same CA twice stores it once")
        func installIsIdempotent() throws {
            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let first = try TLSTrust.install(anchor: der, runner: FakeRunner())
            _ = try TLSTrust.install(anchor: der, runner: FakeRunner())
            defer { try? TLSTrust.remove(fingerprint: first.fingerprint, runner: FakeRunner()) }

            let files = try FileManager.default.contentsOfDirectory(
                at: TLSTrust.anchorDirectory, includingPropertiesForKeys: nil)
            #expect(files.filter { $0.pathExtension == "crt" }.count == 1)
            #expect(TLSTrust.parseCertificates(
                from: try Data(contentsOf: TLSTrust.bundlePath)).count == 1)
        }
    }


    /// A `NODE_EXTRA_CA_CERTS` that belongs to somebody else. Node reads exactly one path, so on a
    /// Mac behind a TLS-inspecting proxy the corporate bundle and this app's bundle are competing for
    /// one variable — and the corporate one was there first. Measured 2026-09-18 from a corporate Mac:
    /// the corporate bundle alone cannot reach the gateway, our anchor alone cannot reach
    /// `api.anthropic.com`, and the two concatenated reach both. So merging is the only configuration
    /// that works, not a compromise.
    ///
    /// `.serialized` because the storage root and the resolver are both process-wide.
    @Suite("a CA bundle this app did not write", .serialized)
    struct ForeignBundle {
        let root: URL

        init() {
            root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "ClaudeSwitchForeign-\(UUID().uuidString)", directoryHint: .isDirectory)
            TLSTrust.storageRoot = root
            TLSTrust.foreignBundlePathResolver = { nil }
        }

        /// A file holding `contents`, under this test's own directory.
        private func write(_ contents: String, named name: String) throws -> String {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appending(path: name)
            try Data(contents.utf8).write(to: url, options: .atomic)
            return url.path(percentEncoded: false)
        }

        private func settingsFile(_ json: String) throws -> ClaudeSettingsStore {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appending(path: "settings-\(UUID().uuidString).json")
            try Data(json.utf8).write(to: url, options: .atomic)
            return ClaudeSettingsStore(url: url)
        }

        private func gatewayProfile() -> Profile {
            var profile = Profile.blank()
            profile.baseURL = "https://gateway.test:4443"
            profile.model = "m"
            profile.caAnchorFingerprint = TLSTrustFingerprintTests.fingerprint
            return profile
        }

        @Test("The foreign bundle's certificates land in bundle.pem alongside the gateway's anchor")
        func mergesIntoTheBundle() throws {
            let foreign = try write(TrustFixtures.unrelatedCA, named: "corporate.pem")
            TLSTrust.foreignBundlePathResolver = { foreign }

            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let outcome = try TLSTrust.install(anchor: der, runner: FakeRunner())
            defer { try? TLSTrust.remove(fingerprint: outcome.fingerprint, runner: FakeRunner()) }

            let bundle = try Data(contentsOf: TLSTrust.bundlePath)
            let fingerprints = Set(TLSTrust.parseCertificates(from: bundle).map(TLSTrust.fingerprint))
            let corporate = try #require(
                TLSTrust.parseCertificates(from: Data(TrustFixtures.unrelatedCA.utf8)).first)

            // Both, in one file — which is the whole point: Node takes one path.
            #expect(fingerprints.contains(TLSTrust.fingerprint(der)))
            #expect(fingerprints.contains(TLSTrust.fingerprint(corporate)))
            #expect(fingerprints.count == 2)
        }

        @Test("A CA in both the foreign bundle and the anchors appears once")
        func deduplicatesByFingerprint() throws {
            let foreign = try write(TrustFixtures.ca + "\n" + TrustFixtures.unrelatedCA,
                                    named: "overlapping.pem")
            TLSTrust.foreignBundlePathResolver = { foreign }

            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let outcome = try TLSTrust.install(anchor: der, runner: FakeRunner())
            defer { try? TLSTrust.remove(fingerprint: outcome.fingerprint, runner: FakeRunner()) }

            let certs = TLSTrust.parseCertificates(from: try Data(contentsOf: TLSTrust.bundlePath))
            #expect(certs.count == 2)
            #expect(certs.filter { TLSTrust.fingerprint($0) == TLSTrust.fingerprint(der) }.count == 1)
        }

        @Test("A foreign path that is not there does not fail the switch, and says why")
        func missingFileIsADiagnosticNotAFailure() throws {
            let missing = root.appending(path: "never-written.pem").path(percentEncoded: false)
            TLSTrust.foreignBundlePathResolver = { missing }

            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            // The install is what a switch depends on; a stale path must not throw out of it.
            let outcome = try TLSTrust.install(anchor: der, runner: FakeRunner())
            defer { try? TLSTrust.remove(fingerprint: outcome.fingerprint, runner: FakeRunner()) }
            #expect(outcome.cliReady)

            let certs = TLSTrust.parseCertificates(from: try Data(contentsOf: TLSTrust.bundlePath))
            #expect(certs.count == 1)

            let report = try #require(TLSTrust.foreignBundle())
            #expect(!report.isUsable)
            #expect(report.problem?.contains("No file at") == true)
        }

        @Test("A file that is not certificates is skipped rather than corrupting the bundle")
        func notACertificate() throws {
            let junk = try write("this is not a certificate\n", named: "notes.txt")
            TLSTrust.foreignBundlePathResolver = { junk }

            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let outcome = try TLSTrust.install(anchor: der, runner: FakeRunner())
            defer { try? TLSTrust.remove(fingerprint: outcome.fingerprint, runner: FakeRunner()) }

            let bundle = try String(contentsOf: TLSTrust.bundlePath, encoding: .utf8)
            #expect(!bundle.contains("not a certificate"))
            #expect(TLSTrust.parseCertificates(from: Data(bundle.utf8)).count == 1)
            #expect(TLSTrust.foreignBundle()?.problem?.contains("no certificates") == true)
        }

        @Test("Our own bundle path is not a foreign value, so it is never merged into itself")
        func selfReferenceIsNotForeign() throws {
            let ours = TLSTrust.bundlePath.path(percentEncoded: false)
            let store = try settingsFile("{\"env\":{\"NODE_EXTRA_CA_CERTS\":\"\(ours)\"}}")

            #expect(try store.readForeignCABundlePath() == nil)
            try store.apply(profile: gatewayProfile(), authToken: "t")
            #expect(store.loadForeignCAStash() == nil)
            #expect(!FileManager.default.fileExists(atPath: store.foreignCAStashURL.path))

            // And on the way back the key goes, as it always did — there was nothing to keep.
            try store.clearManagedEnvironment()
            #expect(try store.readManagedEnvironment()["NODE_EXTRA_CA_CERTS"] == nil)
        }

        @Test("A tilde and a relative path both resolve to a real absolute path")
        func pathExpansion() {
            let home = URL.homeDirectory.path(percentEncoded: false)
            #expect(TLSTrust.resolvePath("~/ca.pem").hasPrefix(home))
            #expect(TLSTrust.resolvePath("~/ca.pem").hasSuffix("/ca.pem"))
            #expect(TLSTrust.resolvePath("certs/ca.pem").hasPrefix(home))
            #expect(TLSTrust.resolvePath("/etc/ssl/ca.pem") == "/etc/ssl/ca.pem")
        }

        @Test("A gateway round trip gives the user's value back, in the position it was found")
        func roundTripRestoresInPlace() throws {
            let foreign = try write(TrustFixtures.unrelatedCA, named: "corporate.pem")
            let store = try settingsFile("""
            {"env":{"FIRST":"a","NODE_EXTRA_CA_CERTS":"\(foreign)","LAST":"z"}}
            """)

            try store.apply(profile: gatewayProfile(), authToken: "t")
            // While the gateway is active the key is ours, and the user's value is parked.
            #expect(try store.readManagedEnvironment()["NODE_EXTRA_CA_CERTS"]
                    == TLSTrust.bundlePath.path(percentEncoded: false))
            #expect(store.loadForeignCAStash()?.path == foreign)
            #expect(store.loadForeignCAStash()?.index == 1)

            try store.clearManagedEnvironment()
            let text = try String(contentsOf: store.url, encoding: .utf8)
            let env = try #require(JSONValue.parse(text)["env"]?.objectEntries)
            #expect(env.map(\.key) == ["FIRST", "NODE_EXTRA_CA_CERTS", "LAST"])
            #expect(env[1].value.stringValue == foreign)
            // The record is consumed, so a later switch stashes afresh rather than replaying this one.
            #expect(!FileManager.default.fileExists(atPath: store.foreignCAStashURL.path))
        }

        @Test("A second switch keeps the first stash, which is the true before state")
        func secondSwitchDoesNotOverwriteTheStash() throws {
            let foreign = try write(TrustFixtures.unrelatedCA, named: "corporate.pem")
            let store = try settingsFile("""
            {"env":{"NODE_EXTRA_CA_CERTS":"\(foreign)"}}
            """)

            try store.apply(profile: gatewayProfile(), authToken: "t")
            // settings.json now holds our path; switching again must not record that as theirs.
            try store.apply(profile: gatewayProfile(), authToken: "t")
            #expect(store.loadForeignCAStash()?.path == foreign)

            try store.clearManagedEnvironment()
            #expect(try store.readUnmanagedEnvironment().isEmpty)
            let restored = try #require(JSONValue.parse(
                try String(contentsOf: store.url, encoding: .utf8))["env"]?.objectEntries)
            #expect(restored.first { $0.key == "NODE_EXTRA_CA_CERTS" }?.value.stringValue == foreign)
        }

        @Test("A user with no bundle of their own sees exactly the old behaviour")
        func noForeignValueIsUnchanged() throws {
            let store = try settingsFile(#"{"env":{"MY_OWN":"keep"}}"#)

            try store.apply(profile: gatewayProfile(), authToken: "t")
            #expect(store.loadForeignCAStash() == nil)

            try store.clearManagedEnvironment()
            let root = try #require(JSONValue.parse(try String(contentsOf: store.url, encoding: .utf8))
                .objectEntries)
            let env = try #require(root.first { $0.key == "env" }?.value.objectEntries)
            // The key is gone, and nothing was invented in its place.
            #expect(env.map(\.key) == ["MY_OWN"])
        }

        @Test("A value set only in the shell or by launchctl is still found, and still merged")
        func processEnvironmentIsADetectionSource() throws {
            let foreign = try write(TrustFixtures.unrelatedCA, named: "corporate.pem")
            // settings.json says nothing; the variable reaches this process from launchd.
            let store = try settingsFile(#"{"env":{}}"#)
            #expect(try store.readForeignCABundlePath() == nil)
            #expect(store.foreignCABundlePath() == nil)

            // The process environment is read through the same filter the settings value is.
            #expect(ClaudeSettingsStore.foreignValue(foreign) == foreign)
            #expect(ClaudeSettingsStore.foreignValue(
                TLSTrust.bundlePath.path(percentEncoded: false)) == nil)
            #expect(ClaudeSettingsStore.foreignValue("   ") == nil)
            #expect(ClaudeSettingsStore.foreignValue(nil) == nil)

            // A detection source only: nothing in settings.json means nothing to restore there.
            TLSTrust.foreignBundlePathResolver = { foreign }
            let der = try #require(TLSTrust.parseCertificates(from: Data(TrustFixtures.ca.utf8)).first)
            let outcome = try TLSTrust.install(anchor: der, runner: FakeRunner())
            defer { try? TLSTrust.remove(fingerprint: outcome.fingerprint, runner: FakeRunner()) }
            #expect(TLSTrust.parseCertificates(
                from: try Data(contentsOf: TLSTrust.bundlePath)).count == 2)

            try store.apply(profile: gatewayProfile(), authToken: "t")
            #expect(store.loadForeignCAStash() == nil)
        }

        @Test("With no anchor of our own there is no bundle, merge or not")
        func noAnchorMeansNoBundle() throws {
            let foreign = try write(TrustFixtures.unrelatedCA, named: "corporate.pem")
            #expect(TLSTrust.bundleContents(from: [:], mergingForeignBundleAt: foreign).isEmpty)
        }

        @Test("Diagnostics carry the foreign bundle, so a kept CA is visible rather than assumed")
        func environmentReportSurfacesIt() throws {
            let foreign = try write(TrustFixtures.unrelatedCA, named: "corporate.pem")
            let report = EnvironmentReport.build(
                profile: gatewayProfile(), token: "t", managed: [:], unmanaged: [:], shell: [],
                foreignCABundle: TLSTrust.inspectForeignBundle(path: foreign))
            let bundle = try #require(report.foreignCABundle)
            #expect(bundle.configuredPath == foreign)
            #expect(bundle.certificateCount == 1)
            #expect(bundle.isUsable)
        }
    }

}

@Suite("TLS trust: what each consumer needs")
struct TLSTrustConsumerTests {
    @Test("Claude Code is told about the CA by env, because Node ignores the keychain")
    func cliNeedsTheEnvKey() {
        // Measured 2026-09-16 with Node v26.5.0: an untrusted chain fails with
        // UNABLE_TO_VERIFY_LEAF_SIGNATURE with the CA in the keychain, and succeeds with
        // NODE_EXTRA_CA_CERTS pointing at it. So this key is not optional polish.
        #expect(ClaudeSettingsStore.managedKeys.contains("NODE_EXTRA_CA_CERTS"))
    }

    @Test("A destination that needs a private anchor carries the key; one that does not, does not")
    func environmentCarriesTheAnchor() {
        var profile = Profile.blank()
        profile.baseURL = "https://gateway.test:4443"
        profile.model = "m"

        let without = profile.environment(authToken: "t")
        #expect(!without.contains { $0.key == "NODE_EXTRA_CA_CERTS" })

        profile.caAnchorFingerprint = TLSTrustFingerprintTests.fingerprint
        let with = profile.environment(authToken: "t")
        let row = with.first { $0.key == "NODE_EXTRA_CA_CERTS" }
        #expect(row?.value == TLSTrust.bundlePath.path(percentEncoded: false))
    }

    @Test("Switching back to Anthropic takes the key off disk with the others")
    func managedKeyIsRemovedOnClear() throws {
        let file = URL(filePath: NSTemporaryDirectory())
            .appending(path: "settings-\(UUID().uuidString).json")
        try Data(#"{"env":{"MY_OWN":"keep"}}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var profile = Profile.blank()
        profile.baseURL = "https://gateway.test:4443"
        profile.model = "m"
        profile.caAnchorFingerprint = TLSTrustFingerprintTests.fingerprint

        let store = ClaudeSettingsStore(url: file)
        try store.apply(profile: profile, authToken: "t")
        #expect(try store.readManagedEnvironment()["NODE_EXTRA_CA_CERTS"] != nil)

        try store.clearManagedEnvironment()
        #expect(try store.readManagedEnvironment()["NODE_EXTRA_CA_CERTS"] == nil)
        // The user's own key is untouched, as with every other managed key.
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("MY_OWN"))
    }
}
