import ClaudeSwitchCore
import SwiftUI
import UniformTypeIdentifiers

/// The row under Base URL that says whether this Mac trusts the gateway's certificate.
///
/// It renders nothing at all when the certificate is trusted, or when the destination is not
/// HTTPS. A gateway with a public CA therefore costs the user no words and no clicks — the whole
/// reason trust is decided by a handshake here rather than by guessing which hosts are "internal".
struct TrustRow: View {
    let baseURL: String
    @Binding var fingerprint: String?

    @State private var status: TLSTrust.Status?
    @State private var isChecking = false
    @State private var showingSheet = false

    var body: some View {
        Group {
            switch status {
            case .trusted:
                if fingerprint != nil {
                    LabeledContent("TLS") {
                        HStack(spacing: 8) {
                            Label("Trusted via your installed CA", systemImage: "lock.fill")
                                .foregroundStyle(.green)
                            Button("Manage…") { showingSheet = true }
                        }
                    }
                }
            case let .untrusted(_, issuer):
                LabeledContent("TLS") {
                    HStack(spacing: 8) {
                        Label(issuer.map { "Signed by \($0), not trusted" }
                              ?? "Certificate not trusted on this Mac",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Fix…") { showingSheet = true }
                    }
                }
            case let .unreachable(message):
                LabeledContent("TLS", value: message)
                    .foregroundStyle(.secondary)
            case .notTLS, .none:
                EmptyView()
            }
        }
        .task(id: baseURL) { await check() }
        .sheet(isPresented: $showingSheet) {
            TrustSheet(baseURL: baseURL, status: status, fingerprint: $fingerprint) {
                Task { await check() }
            }
        }
    }

    private func check() async {
        guard !baseURL.isEmpty else {
            status = nil
            return
        }
        isChecking = true
        status = await TLSTrust.check(baseURL: baseURL)
        isChecking = false
    }
}

/// Obtains the gateway's CA, makes the user verify its fingerprint, and installs it for both
/// consumers that need it.
struct TrustSheet: View {
    let baseURL: String
    let status: TLSTrust.Status?
    @Binding var fingerprint: String?
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var candidate: Data?
    @State private var summary: TLSTrust.CertificateSummary?
    @State private var typed = ""
    @State private var problem: String?
    @State private var outcome: TLSTrust.InstallOutcome?
    @State private var isWorking = false

    private var leaf: Data? {
        if case let .untrusted(leaf, _) = status { return leaf }
        return nil
    }

    private var confirmed: Bool {
        guard let summary else { return false }
        return TLSTrust.confirms(typed, matches: summary.sha256)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust this gateway's certificate")
                .font(.headline)

            if let outcome {
                result(outcome)
            } else if let summary {
                review(summary)
            } else {
                intro
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This gateway's certificate is signed by a private authority that this Mac does "
                 + "not know. To use it, that authority's certificate has to be installed.")
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Fetch from the gateway") { Task { await fetch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                Button("Choose file…") { choose() }
                    .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Text("Fetching asks the gateway for its own authority certificate, over a connection "
                 + "that cannot yet be verified — so it proves nothing on its own. You will be "
                 + "asked to check its fingerprint against what your administrator told you, and "
                 + "that check is what makes it trustworthy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func review(_ summary: TLSTrust.CertificateSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Authority").foregroundStyle(.secondary)
                    Text(summary.subject).fontWeight(.medium)
                }
                GridRow {
                    Text("Issued by").foregroundStyle(.secondary)
                    Text(summary.issuer)
                }
                if let notAfter = summary.notAfter {
                    GridRow {
                        Text("Expires").foregroundStyle(.secondary)
                        Text(notAfter.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(summary.isExpired ? .red : .primary)
                    }
                }
            }

            Divider()

            Text("SHA-256 fingerprint")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary.sha256)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text("Confirm the **last four pairs** to show you compared this with your "
                 + "administrator's copy — not with the server that just sent it.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("00:00:00:00", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 140)
                    .autocorrectionDisabled()
                if confirmed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if !typed.isEmpty {
                    Text("Does not match").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Installing writes the certificate where Claude Code can read it, and asks macOS "
                 + "to trust it for SSL in your login keychain — where Claude Desktop reads it. "
                 + "macOS will ask for your password. Nothing is changed for other users of this "
                 + "Mac, and you can undo it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Install") { Task { await install() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!confirmed || isWorking || summary.isExpired)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func result(_ outcome: TLSTrust.InstallOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Reported per consumer, because the halves fail independently and "it didn't work"
            // would send the user straight back to guessing.
            consumer("Claude Code", ok: outcome.cliReady,
                     detail: outcome.cliReady
                        ? "NODE_EXTRA_CA_CERTS will be written while this destination is active."
                        : "The certificate could not be filed.")
            consumer("Claude Desktop", ok: outcome.keychainTrusted,
                     detail: outcome.keychainTrusted
                        ? "Trusted for SSL in your login keychain."
                        : (outcome.keychainMessage ?? "Not trusted."))

            if !outcome.isComplete, let message = outcome.keychainMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Remove trust") { Task { await removeTrust() } }
                    .disabled(isWorking)
                Spacer()
                Button("Done") {
                    onFinish()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func consumer(_ name: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private func fetch() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }

        guard let data = await TLSTrust.fetchCandidateAnchor(baseURL: baseURL, leaf: leaf) else {
            problem = "No authority certificate was served at any of the usual paths "
                + "(\(TLSTrust.candidateAnchorPaths.joined(separator: ", "))), or what was served "
                + "did not sign this gateway's certificate. Ask your administrator for the file."
            return
        }
        accept(data)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "crt") ?? .data,
                                     UTType(filenameExtension: "pem") ?? .data,
                                     UTType(filenameExtension: "cer") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.prompt = "Use certificate"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url)
        else { return }
        problem = nil
        accept(data)
    }

    /// Validates a candidate before the fingerprint is ever shown, so a wrong file cannot get
    /// as far as being confirmed.
    private func accept(_ data: Data) {
        guard let der = TLSTrust.parseCertificates(from: data).first else {
            problem = "That file does not contain a certificate."
            return
        }
        guard TLSTrust.isCertificateAuthority(der) else {
            problem = "That certificate is not a certificate authority, so nothing can be trusted "
                + "through it. A server's own certificate cannot be used here — Claude Code "
                + "refuses one as a trust anchor even when macOS accepts it."
            return
        }
        if let leaf {
            guard der != leaf, TLSTrust.anchor(der, verifies: leaf) else {
                problem = "That authority did not sign this gateway's certificate, so trusting it "
                    + "would not help — and would trust someone else's gateway."
                return
            }
        }
        candidate = der
        summary = TLSTrust.summarize(der)
    }

    private func install() async {
        guard let candidate, let summary else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try TLSTrust.install(anchor: candidate)
            fingerprint = summary.sha256
            outcome = result
        } catch {
            problem = "Could not install: \(error.localizedDescription)"
        }
    }

    private func removeTrust() async {
        guard let summary else { return }
        isWorking = true
        defer { isWorking = false }
        _ = try? TLSTrust.remove(fingerprint: summary.sha256)
        fingerprint = nil
        onFinish()
        dismiss()
    }
}
