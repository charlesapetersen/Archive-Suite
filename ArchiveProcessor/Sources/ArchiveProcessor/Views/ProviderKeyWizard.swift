import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Guided, reusable onboarding wizard for creating + validating a provider API key. Driven by
/// `ProviderKeySpec`, so one component serves Gemini and Mistral (and is reusable on iOS via
/// ArchiveCore later). Each provider is independent and skippable; the app works with any one key.
struct ProviderKeyWizard: View {
    let specs: [ProviderKeySpec]
    var onClose: () -> Void

    @State private var selection: String

    init(specs: [ProviderKeySpec] = ProviderKeySpec.onboardable, onClose: @escaping () -> Void = {}) {
        self.specs = specs
        self.onClose = onClose
        _selection = State(initialValue: specs.first?.id ?? "")
    }

    private var selected: ProviderKeySpec? { specs.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Set up your API keys").font(.title2).bold()
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if specs.count > 1 {
                Picker("", selection: $selection) {
                    ForEach(specs) { Text($0.displayName).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
            }

            ScrollView {
                if let spec = selected {
                    ProviderKeyStep(spec: spec).id(spec.id).padding([.horizontal, .bottom])
                }
            }
        }
        .frame(minWidth: 540, minHeight: 620)
    }
}

/// One provider's guided step: explain → open the page → paste → validate (live) → plain-English status.
private struct ProviderKeyStep: View {
    let spec: ProviderKeySpec
    @Environment(\.openURL) private var openURL
    @State private var key: String = ""
    @State private var reveal = false
    @State private var validating = false
    @State private var status: KeyValidator.KeyStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(spec.blurb).font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(spec.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").bold().frame(width: 18, alignment: .trailing)
                        Text(step)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Button { openURL(spec.signInURL) } label: {
                Label("Open \(spec.displayName)", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)

            if let card = spec.cardNote { noteRow("exclamationmark.bubble", card) }
            noteRow("dollarsign.circle", spec.costNote)
            noteRow("lock.circle", spec.privacyNote)

            Divider().padding(.vertical, 4)

            Text("Paste your \(spec.displayName) key").font(.headline)
            HStack(spacing: 6) {
                Group {
                    if reveal { TextField("\(spec.displayName) API key", text: $key) }
                    else { SecureField("\(spec.displayName) API key", text: $key) }
                }
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { _, _ in status = nil }
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                #if canImport(AppKit)
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        key = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                #endif
            }

            if !key.isEmpty && !spec.keyPrecheck(key) {
                Text("That doesn’t look like a \(spec.displayName) key — re-copy it from the page above.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Button { validate() } label: {
                if validating { ProgressView().controlSize(.small) } else { Text("Validate key") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validating)

            if let status { statusView(status) }
        }
        .onAppear { key = KeychainHelper.load(account: spec.account) ?? "" }
    }

    private func noteRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func validate() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        validating = true
        status = nil
        Task {
            let result = await spec.validate(trimmed)
            validating = false
            status = result
            if result.isUsable {
                KeychainHelper.save(account: spec.account, password: trimmed)
                UserDefaults.standard.set(true, forKey: "keyValidated_\(spec.account)")
                NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
            }
        }
    }

    @ViewBuilder private func statusView(_ s: KeyValidator.KeyStatus) -> some View {
        let ok = s.isUsable
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(s.message(provider: spec.displayName)).font(.callout)
            }
            switch s {
            case .needsBilling:
                if let u = spec.billingURL { Button("Enable billing") { openURL(u) } }
            case .ocrNotEnabled:
                if let u = spec.billingURL { Button("Add a payment method in \(spec.displayName)") { openURL(u) } }
            default:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((ok ? Color.green : Color.orange).opacity(0.12)))
    }
}
