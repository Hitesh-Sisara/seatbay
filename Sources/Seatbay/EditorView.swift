import SeatbayCore
import SwiftUI

/// Sheet for creating or editing an instance, with a live Dock-icon preview.
struct EditorView: View {
    let target: EditorTarget
    @EnvironmentObject private var store: InstanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Instance
    @State private var copyMainData = false
    @State private var saving = false
    @State private var useAPI: Bool
    @State private var api: APIConnection
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    /// The saved key when Claude has sealed it; kept unless a new key is typed.
    @State private var sealedKey: String?

    init(target: EditorTarget) {
        self.target = target
        let instance = target.instance
        _draft = State(initialValue: instance)
        _useAPI = State(initialValue: instance.usesAPI)
        let apiDir = URL(fileURLWithPath: instance.apiDataDir, isDirectory: true)
        var saved = APIConfigFile.load(dataDir: apiDir) ?? APIConfigFile.loadDisabled(dataDir: apiDir) ?? APIConnection()
        if saved.isSealed {
            _sealedKey = State(initialValue: saved.apiKey)
            saved.apiKey = ""
        }
        _api = State(initialValue: saved)
    }

    /// What gets saved: the typed key, or the sealed one when the field was left empty.
    private var effectiveAPI: APIConnection {
        var connection = api
        if connection.trimmedKey.isEmpty, let sealedKey { connection.apiKey = sealedKey }
        return connection
    }

    private var problem: String? {
        if let problem = store.nameProblem(draft.name, excluding: draft.id) { return problem }
        if useAPI, let problem = effectiveAPI.problem { return problem }
        if !target.isNew, useAPI != target.instance.usesAPI, store.isRunning(target.instance) {
            return "Quit \(target.instance.name) first to change how it connects."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(target.isNew ? "New Claude Instance" : "Edit \(target.instance.name)")
                .font(.title3.weight(.bold))

            HStack(alignment: .top, spacing: 26) {
                preview
                form
            }

            connection

            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || saving)
            }
        }
        .padding(22)
        .frame(width: 660)
    }

    /// The draft as it will be saved, so the preview shows the API tag as soon as "API key" is picked.
    private var previewInstance: Instance {
        var instance = draft
        instance.dataDir = useAPI ? draft.apiDataDir : draft.accountDataDir
        return instance
    }

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.quaternary.opacity(0.5))
                if let image = store.previewIcon(for: previewInstance) {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 150, height: 150)
                }
            }
            .frame(width: 176, height: 176)
            Text(draft.name.isEmpty ? "Untitled" : draft.name)
                .font(.callout.weight(.medium)).lineLimit(1)
            // Small sizes, the way it will look in the Dock and in app switchers.
            HStack(spacing: 10) {
                if let image = store.previewIcon(for: previewInstance) {
                    ForEach([48, 32, 16], id: \.self) { size in
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: CGFloat(size), height: CGFloat(size))
                    }
                }
            }
        }
        .frame(width: 176)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Name") {
                TextField("Claude Work", text: $draft.name).textFieldStyle(.roundedBorder)
            }
            field("Number") {
                Stepper(value: $draft.number, in: 1...99) {
                    Text("\(draft.number)").monospacedDigit().frame(minWidth: 24, alignment: .leading)
                }
            }
            field("Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                    ForEach(Palette.names, id: \.self) { name in
                        Button {
                            draft.colorName = name
                        } label: {
                            Circle()
                                .fill(Palette.swiftUIColor(named: name))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: draft.colorName == name ? 2 : 0))
                                .padding(2)
                                .overlay(Circle().strokeBorder(draft.colorName == name ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
            field("Icon") {
                Picker("Icon", selection: $draft.style) {
                    ForEach(IconStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            field("Label") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Optional, e.g. WORK", text: $draft.label).textFieldStyle(.roundedBorder)
                        .onChange(of: draft.label) { _, value in
                            if value.count > 10 { draft.label = String(value.prefix(10)) }
                        }
                    Text("Shown as a strip across the top of the icon.").font(.caption).foregroundStyle(.secondary)
                }
            }
            field("Sleep") {
                Toggle("Never put this instance to sleep", isOn: Binding(get: { draft.neverSleep == true },
                                                                       set: { draft.neverSleep = $0 ? true : nil }))
            }
            if target.isNew && !useAPI {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Start with a copy of my main Claude's data", isOn: $copyMainData)
                    Text("Copies sign-in, settings and history, so it opens signed in to the same account. Leave this off to sign in to a different account. For the cleanest copy, quit Claude first.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Connect with").foregroundStyle(.secondary)
                Picker("Connect with", selection: $useAPI) {
                    Text("Claude account").tag(false)
                    Text("API key").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            if useAPI {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        label("Base URL")
                        TextField("Blank for Anthropic's API, or e.g. https://gateway.example.com/anthropic", text: $api.baseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        label("API key")
                        SecureField(sealedKey != nil ? "Saved, sealed in the keychain by Claude. Type a new key to replace it."
                                                     : api.isGateway ? "Gateway key" : "sk-ant-…",
                                    text: $api.apiKey).textFieldStyle(.roundedBorder)
                    }
                    if api.isGateway {
                        GridRow {
                            label("Send key as")
                            Picker("Send key as", selection: $api.authScheme) {
                                ForEach(APIConnection.AuthScheme.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                        }
                    }
                    GridRow {
                        label("Models")
                        TextField("Optional: model ids for the model menu, e.g. claude-opus-5-5, claude-sonnet-5-5", text: $api.modelsText)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        label("Headers")
                        TextField("Optional: one per line, Name: value", text: $api.headersText, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Test Connection") { test() }
                        .disabled(testing || effectiveAPI.problem != nil)
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? .green : .red)
                            .font(.callout).lineLimit(2)
                    }
                }
                Text("No Claude account sign-in: this instance sends its chats, Cowork and Code sessions to the API with this key. The key is kept only in the instance's own data folder (readable by you alone), like a sign-in is. Changes apply the next time the instance opens.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !target.isNew, target.instance.usesAPI {
                Text("Goes back to the Claude account folder this instance used before (or a new one). Its API settings are kept aside in case you switch back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
        .onChange(of: api) { _, _ in testResult = nil }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func test() {
        testing = true
        testResult = nil
        let connection = effectiveAPI
        Task {
            let result = await connection.test()
            testResult = result
            testing = false
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
            content()
        }
    }

    private func save() {
        saving = true
        Task {
            if target.isNew {
                await store.create(draft, copyMainData: copyMainData && !useAPI, api: useAPI ? effectiveAPI : nil)
            } else {
                store.update(draft, api: useAPI ? effectiveAPI : nil)
            }
            saving = false
            dismiss()
        }
    }
}
