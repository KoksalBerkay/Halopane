import SwiftUI
import SpatialMath
import UniformTypeIdentifiers

/// Ad blocking settings on the iPhone.
struct AdBlockingSettings: View {
    @ObservedObject var store: AdBlockingStore
    @ObservedObject var bundled: BrowserContentBlocker
    @State private var inputURL = ""
    @State private var picking = false
    @State private var importBackup = false
    @State private var exporting = false
    @State private var backup: RulesBackupDocument?
    @State private var askReset = false
    @State private var importError: String?

    var body: some View {
        Form {
            if let busy = store.busy {
                ProgressView(busy)
            }
            if let message = importError ?? store.message {
                lastOperationSection(message)
            }
            listsSection
            addListSection
            myRulesSection
            siteExceptionsSection
            backupSection
        }
        .navigationTitle("Ad blocking")
        .fileImporter(
            isPresented: $picking, allowedContentTypes: importBackup ? [.json] : [.plainText, .json, .data]
        ) { result in
            handlePickedFile(result)
        }
        .fileExporter(
            isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "Halopane-Ad-Blocking"
        ) { result in
            backup = nil
            if case .failure = result {
                importError = "Couldn’t export the backup."
            }
        }
        .confirmationDialog("Reset ad blocking?", isPresented: $askReset, titleVisibility: .visible) {
            Button("Remove added lists, rules and site exceptions", role: .destructive) {
                Task {
                    await store.reset()
                }
            }
        }
    }

    // Result of the last import or update, with examples of skipped lines.
    private func lastOperationSection(_ message: String) -> some View {
        Section("Last operation") {
            Text(message)
            if let imported = store.lastImport {
                ForEach(imported.examples, id: \.line) { item in
                    VStack(alignment: .leading) {
                        Text("Line \(item.line): \(item.reason)")
                        Text(item.text).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            }
        }
    }

    // Master switch, the bundled lists and every list the user added.
    private var listsSection: some View {
        Section("Lists") {
            Toggle(
                "Block ads",
                isOn: Binding(
                    get: { store.state.masterEnabled },
                    set: { enabled in
                        Task {
                            await store.setMasterEnabled(enabled)
                        }
                    })
            )
            .disabled(store.busy != nil)
            bundledListToggle
            ForEach(store.userSources) { source in
                userSourceRow(source)
            }
            Text("Changes apply to all screens. Reload a page to see the full effect.").font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var bundledListToggle: some View {
        Toggle(
            isOn: Binding(
                get: { store.state.bundledEnabled },
                set: { enabled in
                    Task {
                        await store.setBundledEnabled(enabled)
                    }
                }
            )
        ) {
            VStack(alignment: .leading) {
                Text("Bundled EasyList and EasyPrivacy")
                Text("\(bundled.ruleCount) rules · \(bundled.updatedLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                if bundled.list == nil {
                    Text(bundled.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(store.busy != nil)
    }

    // One added list: on/off, rule count, skipped lines, and Update/Remove.
    private func userSourceRow(_ source: AdBlockingStore.Source) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                source.name,
                isOn: Binding(
                    get: {
                        store.userSources.first(where: { $0.id == source.id })?.enabled ?? false
                    },
                    set: { enabled in
                        Task {
                            await store.setEnabled(source.id, enabled)
                        }
                    }))
            Text("\(source.count) rules · Updated \(source.updated.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            if store.unavailable.contains(source.id) {
                Text("Couldn’t load this list.").font(.caption).foregroundStyle(.secondary)
            }
            if source.skipped > 0 || source.exceptions > 0 {
                DisclosureGroup("\(source.skipped) skipped · \(source.exceptions) list-only exceptions") {
                    ForEach(source.examples, id: \.line) { example in
                        Text("Line \(example.line): \(example.reason): \(example.text)").font(.caption)
                            .textSelection(.enabled)
                    }
                }.font(.caption)
            }
            HStack {
                if source.kind == .url {
                    Button("Update") {
                        Task {
                            await store.update(source)
                        }
                    }.buttonStyle(.borderless)
                }
                Button("Remove", role: .destructive) {
                    Task {
                        await store.remove(source.id)
                    }
                }
                .buttonStyle(.borderless)
            }
        }.disabled(store.busy != nil)
    }

    private var addListSection: some View {
        Section("Add a list") {
            Button("Add from Files") {
                importError = nil
                importBackup = false
                picking = true
            }
            TextField("https://…", text: $inputURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add HTTPS list") {
                importError = nil
                let address = inputURL
                Task {
                    await store.addURL(address)
                    if store.lastImport != nil {
                        inputURL = ""
                    }
                }
            }.disabled(inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(
                """
                \(store.userSources.count) of 10 added lists. \
                Halopane connects to a list address only when you add it or tap Update.
                """
            )
            .font(.footnote).foregroundStyle(.secondary)
        }.disabled(store.busy != nil || store.userSources.count >= ContentRuleConversion.sourceLimit)
    }

    private var myRulesSection: some View {
        Section("My rules") {
            NavigationLink {
                AdBlockingRuleEditor(store: store)
            } label: {
                if let editor = store.editor {
                    LabeledContent("Edit rules", value: "\(editor.count)")
                } else {
                    Text("Edit rules")
                }
            }.disabled(store.busy != nil)
            if let editor = store.editor {
                Toggle(
                    "Enable My rules",
                    isOn: Binding(
                        get: { store.editor?.enabled ?? false },
                        set: { value in
                            Task {
                                await store.setEnabled(editor.id, value)
                            }
                        })
                )
                .disabled(store.busy != nil)
            }
        }
    }

    private var siteExceptionsSection: some View {
        Section("Sites with blocking off") {
            if store.state.sites.isEmpty {
                Text("No site exceptions.").foregroundStyle(.secondary)
            }
            ForEach(store.state.sites, id: \.self) { site in
                HStack {
                    Text(site)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        Task {
                            await store.removeSites([site])
                        }
                    }
                    .buttonStyle(.borderless)
                }.disabled(store.busy != nil)
            }
        }
    }

    private var backupSection: some View {
        Section("Backup") {
            Button("Import settings backup") {
                importError = nil
                importBackup = true
                picking = true
            }
            Button("Export settings backup") {
                exportBackup()
            }
            Button("Reset to defaults", role: .destructive) {
                askReset = true
            }
            Text(
                """
                A backup includes list snapshots and site exceptions. \
                Import replaces these settings without downloading anything.
                """
            ).font(.footnote).foregroundStyle(.secondary)
        }.disabled(store.busy != nil)
    }

    private func exportBackup() {
        // Encoding large snapshots must not occupy the phone UI.
        let state = store.state
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .utility) {
                    try JSONEncoder().encode(state)
                }.value
                backup = RulesBackupDocument(data: data)
                exporting = true
            } catch {
                importError = "Couldn’t create the backup."
            }
        }
    }

    // The same file picker serves both list import and backup restore.
    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            let restore = importBackup
            Task {
                if restore {
                    await store.restore(url)
                } else {
                    await store.addFile(url)
                }
            }
        case .failure:
            importError = "Couldn’t open the file."
        }
    }
}

/// File wrapper for importing and exporting a settings backup.
private struct RulesBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) {
        self.data = data
    }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= AdBlockingStore.backupLimit else {
            throw ContentRuleConversion.Failure.invalidBackup
        }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Editor for the "My rules" list.
private struct AdBlockingRuleEditor: View {
    @ObservedObject var store: AdBlockingStore
    @State private var text = ""
    @State private var domain = ""
    @State private var selector = ""
    @State private var issues = [ContentRuleConversion.Example]()
    @State private var validationRunning = false
    @State private var initialized = false

    var body: some View {
        Form {
            shortcutsSection
            rulesSection
        }
        .navigationTitle("My rules")
        .onAppear {
            loadSavedRulesOnce()
        }
        .onChange(of: text) { _ in
            validationRunning = true
        }
        .task(id: text) {
            await validate()
        }
    }

    // Quick ways to add a domain block or an element-hiding rule.
    private var shortcutsSection: some View {
        Section("Shortcuts") {
            TextField("example.com", text: $domain)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Block this domain") {
                append("||" + normalizedDomain + "^$document")
                domain = ""
            }.disabled(!ContentRuleConversion.validHost(normalizedDomain))
            TextField("CSS selector, e.g. .ad-banner", text: $selector)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Hide this element by CSS selector") {
                append("##" + selector)
                selector = ""
            }
            .disabled(selector.isEmpty)
        }
    }

    private var normalizedDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var rulesSection: some View {
        Section("One Adblock Plus rule per line") {
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 180)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            ForEach(issues.prefix(8), id: \.line) { item in
                Text("Line \(item.line): \(item.reason)").font(.caption).foregroundStyle(.red)
            }
            if issues.count > 8 {
                Text("Plus \(issues.count-8) more invalid lines.").font(.caption)
            }
            if text.contains("@@") {
                Text(AdBlockingStore.exceptionNotice).font(.footnote).foregroundStyle(.secondary)
            }
            if let busy = store.busy {
                ProgressView(busy)
            }
            if let message = store.message {
                Text(message).font(.footnote)
            }
            Button("Save rules") {
                let draft = text
                Task {
                    await store.saveEditor(draft)
                }
            }.disabled(!issues.isEmpty || validationRunning || store.busy != nil)
            Text("Clear the editor and save to delete your rules.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // Fill the editor from the saved rules the first time the screen appears.
    private func loadSavedRulesOnce() {
        guard !initialized else {
            return
        }
        initialized = true
        if let source = store.editor {
            text = String(decoding: source.snapshot, as: UTF8.self)
        }
    }

    // Checks every line off the main thread. A newer edit cancels this check.
    private func validate() async {
        let value = text
        guard value.utf8.count <= ContentRuleConversion.byteLimit else {
            issues = [.init(line: 1, text: "", reason: "Text exceeds the 16 MiB limit")]
            validationRunning = false
            return
        }
        let result = await Task.detached(priority: .utility) {
            ContentRuleConversion.editorExamples(value)
        }
        .value
        if !Task.isCancelled {
            issues = result
            validationRunning = false
        }
    }

    private func append(_ line: String) {
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += line + "\n"
    }
}
