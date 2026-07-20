import SwiftUI

struct ProvidersPane: View {
    @Bindable private var store = AIProviderStore.shared

    @State private var editorDraft: ProviderEditorDraft?
    @State private var profilePendingDelete: AIProviderProfile?
    @State private var statusText: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            introduction
            providersSection
            if let statusText {
                Text(statusText)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(statusColor(for: statusText))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let storeError = store.lastError, statusText == nil {
                Text(storeError)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { store.configure() }
        .sheet(item: $editorDraft) { draft in
            ProviderEditorSheet(draft: draft) { message in
                statusText = message
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { profilePendingDelete != nil },
                set: { if !$0 { profilePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = profilePendingDelete {
                    deleteProfile(profile)
                }
            }
            Button("Cancel", role: .cancel) {
                profilePendingDelete = nil
            }
        } message: {
            Text("This removes the provider configuration and any stored credentials from the Keychain.")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("AI chat and generation can use multiple custom providers. API keys are stored in the macOS Keychain.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            Menu {
                ForEach(AIProviderPreset.allCases) { preset in
                    Button(preset.label) {
                        editorDraft = ProviderEditorDraft(profile: preset.makeProfile(), isNew: true)
                    }
                }
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .disabled(isBusy)
        }
    }

    private var providersSection: some View {
        SettingsSection(title: "Providers") {
            if store.profiles.isEmpty {
                Text(store.isLoaded ? "No providers configured." : "Loading providers…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                        providerRow(profile)
                        if index < store.profiles.count - 1 {
                            Divider().overlay(AppTheme.Border.subtleColor)
                        }
                    }
                }
                .padding(.vertical, AppTheme.Spacing.xs)
            }
        }
    }

    private func providerRow(_ profile: AIProviderProfile) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(profile.name)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)

                    if store.activeAgentProfileID == profile.id, profile.agent != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Accent.link)
                            .help("Agent default")
                    }
                }

                Text(hostLabel(for: profile))
                    .font(.system(size: AppTheme.FontSize.xs).monospaced())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(purposeBadges(for: profile), id: \.self) { badge in
                        purposeBadge(badge)
                    }
                    Text(protocolLabel(for: profile))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    Text(credentialLabel(for: profile))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(credentialColor(for: profile))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            Toggle(
                "",
                isOn: Binding(
                    get: { profile.enabled },
                    set: { setEnabled(profile, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isBusy)
            .accessibilityLabel("Enabled")

            Menu {
                if profile.agent != nil {
                    Button("Set as Agent Default") {
                        setActiveAgent(profile)
                    }
                    .disabled(store.activeAgentProfileID == profile.id || !profile.enabled || isBusy)
                }

                if !profile.isManagedPalmier {
                    Button("Edit") {
                        editorDraft = ProviderEditorDraft(profile: profile, isNew: false)
                    }
                    Button("Duplicate") {
                        editorDraft = ProviderEditorDraft(profile: duplicatedProfile(from: profile), isNew: true)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        profilePendingDelete = profile
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .padding(AppTheme.Spacing.xs)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
            .accessibilityLabel("Provider actions")
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var deleteDialogTitle: String {
        if let name = profilePendingDelete?.name {
            return "Delete “\(name)”?"
        }
        return "Delete provider?"
    }

    private func hostLabel(for profile: AIProviderProfile) -> String {
        if profile.isManagedPalmier { return "Palmier managed" }
        return URL(string: profile.baseURL)?.host ?? profile.baseURL
    }

    private func purposeBadges(for profile: AIProviderProfile) -> [String] {
        var badges: [String] = []
        if profile.agent != nil { badges.append("Agent") }
        if profile.generation != nil { badges.append("Generation") }
        return badges
    }

    private func purposeBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                Capsule()
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
    }

    private func protocolLabel(for profile: AIProviderProfile) -> String {
        if let agent = profile.agent {
            return agent.wireProtocol.label
        }
        if let generation = profile.generation {
            return generation.providerKind.label
        }
        return "—"
    }

    private func credentialLabel(for profile: AIProviderProfile) -> String {
        if profile.isManagedPalmier { return "Managed" }
        return store.hasCredential(for: profile) ? "Ready" : "Missing key"
    }

    private func credentialColor(for profile: AIProviderProfile) -> Color {
        if profile.isManagedPalmier { return AppTheme.Text.tertiaryColor }
        return store.hasCredential(for: profile) ? AppTheme.Text.secondaryColor : AppTheme.Status.errorColor
    }

    private func statusColor(for text: String) -> Color {
        let lowered = text.lowercased()
        if lowered.contains("fail") || lowered.contains("error") || lowered.contains("unable") {
            return AppTheme.Status.errorColor
        }
        return AppTheme.Text.tertiaryColor
    }

    private func duplicatedProfile(from profile: AIProviderProfile) -> AIProviderProfile {
        let now = Date()
        return AIProviderProfile(
            id: UUID(),
            name: profile.name + " Copy",
            baseURL: profile.baseURL,
            enabled: profile.enabled,
            allowInsecureHTTP: profile.allowInsecureHTTP,
            allowCredentialRedirects: profile.allowCredentialRedirects,
            auth: profile.auth,
            headers: profile.headers.map { header in
                ProviderHeaderConfiguration(
                    id: UUID(),
                    name: header.name,
                    value: header.isSecret ? nil : header.value,
                    isSecret: header.isSecret
                )
            },
            agent: profile.agent,
            generation: profile.generation,
            createdAt: now,
            updatedAt: now
        )
    }

    private func setEnabled(_ profile: AIProviderProfile, enabled: Bool) {
        guard profile.enabled != enabled else { return }
        isBusy = true
        statusText = nil
        Task {
            do {
                var updated = profile
                updated.enabled = enabled
                try await store.saveProfile(updated)
                statusText = enabled ? "Provider enabled." : "Provider disabled."
            } catch {
                statusText = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func setActiveAgent(_ profile: AIProviderProfile) {
        isBusy = true
        statusText = nil
        Task {
            do {
                try await store.setActiveAgentProfile(id: profile.id)
                statusText = "“\(profile.name)” is the Agent default."
            } catch {
                statusText = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func deleteProfile(_ profile: AIProviderProfile) {
        profilePendingDelete = nil
        isBusy = true
        statusText = nil
        Task {
            do {
                try await store.deleteProfile(id: profile.id)
                statusText = "Deleted “\(profile.name)”."
            } catch {
                statusText = error.localizedDescription
            }
            isBusy = false
        }
    }
}

// MARK: - Editor draft

private struct ProviderEditorDraft: Identifiable {
    var id: UUID { profileID }

    var profileID: UUID
    var createdAt: Date
    var isNew: Bool

    var name: String
    var baseURL: String
    var enabled: Bool
    var allowInsecureHTTP: Bool
    var allowCredentialRedirects: Bool

    var authKind: ProviderAuthKind
    var authHeaderName: String
    var authValuePrefix: String
    var apiKey: String

    var agentEnabled: Bool
    var agentProtocol: AgentWireProtocol
    var agentEndpoint: String
    var agentDefaultModel: String
    var agentModelsText: String
    var agentMaxOutputTokens: String
    var agentAdditionalBodyText: String

    var generationEnabled: Bool
    var generationKind: GenerationProviderKind
    var generationEndpoint: String
    var generationModelIDsText: String
    var generationOptionsText: String

    var headers: [HeaderDraft]

    struct HeaderDraft: Identifiable, Equatable {
        var id: UUID
        var name: String
        var isSecret: Bool
        var value: String
    }

    init(profile: AIProviderProfile, isNew: Bool) {
        profileID = profile.id
        createdAt = profile.createdAt
        self.isNew = isNew

        name = profile.name
        baseURL = profile.baseURL
        enabled = profile.enabled
        allowInsecureHTTP = profile.allowInsecureHTTP
        allowCredentialRedirects = profile.allowCredentialRedirects

        authKind = profile.auth.kind == .palmierManaged ? .bearer : profile.auth.kind
        authHeaderName = profile.auth.headerName ?? ""
        authValuePrefix = profile.auth.valuePrefix ?? ""
        apiKey = ""

        if let agent = profile.agent {
            agentEnabled = true
            agentProtocol = agent.wireProtocol == .palmierManaged ? .openAIResponses : agent.wireProtocol
            agentEndpoint = agent.endpointPath
            agentDefaultModel = agent.defaultModelID
            agentModelsText = agent.models.map(\.modelID).joined(separator: "\n")
            agentMaxOutputTokens = String(agent.maxOutputTokens)
            agentAdditionalBodyText = Self.encodeJSONObject(agent.additionalBody)
        } else {
            agentEnabled = false
            agentProtocol = .openAIResponses
            agentEndpoint = AgentWireProtocol.openAIResponses.defaultEndpointPath
            agentDefaultModel = ""
            agentModelsText = ""
            agentMaxOutputTokens = "16384"
            agentAdditionalBodyText = "{}"
        }

        if let generation = profile.generation {
            generationEnabled = true
            generationKind = generation.providerKind == .palmierManaged ? .compatibleV1 : generation.providerKind
            generationEndpoint = generation.endpointPath ?? ""
            generationModelIDsText = generation.modelIDs.joined(separator: "\n")
            generationOptionsText = Self.encodeJSONObject(generation.options)
        } else {
            generationEnabled = false
            generationKind = .falQueue
            generationEndpoint = ""
            generationModelIDsText = ""
            generationOptionsText = "{}"
        }

        headers = profile.headers.map { header in
            HeaderDraft(
                id: header.id,
                name: header.name,
                isSecret: header.isSecret,
                value: header.isSecret ? "" : (header.value ?? "")
            )
        }
    }

    static var selectableAuthKinds: [ProviderAuthKind] {
        [.bearer, .xAPIKey, .customHeader, .none]
    }

    static var selectableAgentProtocols: [AgentWireProtocol] {
        AgentWireProtocol.allCases.filter { $0 != .palmierManaged }
    }

    static var selectableGenerationKinds: [GenerationProviderKind] {
        GenerationProviderKind.allCases.filter { $0 != .palmierManaged }
    }

    var requiresPrimaryCredential: Bool {
        switch authKind {
        case .bearer, .xAPIKey, .customHeader: true
        case .none, .palmierManaged: false
        }
    }

    var showsInsecureHTTPWarning: Bool {
        guard allowInsecureHTTP else { return false }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return scheme == "http" && !AIProviderEndpoint.isLoopbackHost(host)
    }

    mutating func applyAgentProtocolChange(from oldProtocol: AgentWireProtocol, to newProtocol: AgentWireProtocol) {
        let trimmedEndpoint = agentEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEndpoint.isEmpty || trimmedEndpoint == oldProtocol.defaultEndpointPath {
            agentEndpoint = newProtocol.defaultEndpointPath
        }
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseURL = newProtocol.defaultBaseURL
        }
    }

    func makeProfile() throws -> (
        profile: AIProviderProfile,
        primaryCredential: String?,
        secretHeaderValues: [UUID: String]
    ) {
        guard agentEnabled || generationEnabled else {
            throw ProviderEditorLocalError.missingService
        }

        let additionalBody = try Self.parseJSONObject(agentAdditionalBodyText, fieldName: "Agent additional JSON")
        let generationOptions = try Self.parseJSONObject(generationOptionsText, fieldName: "Generation options JSON")

        let defaultModel = agentDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = Self.parseModelLines(agentModelsText, defaultModelID: defaultModel)
        let maxTokens = Int(agentMaxOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let agent: AgentEndpointConfiguration?
        if agentEnabled {
            agent = AgentEndpointConfiguration(
                wireProtocol: agentProtocol,
                endpointPath: agentEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                defaultModelID: defaultModel,
                models: models,
                maxOutputTokens: maxTokens,
                additionalBody: additionalBody
            )
        } else {
            agent = nil
        }

        let generation: GenerationEndpointConfiguration?
        if generationEnabled {
            let endpoint = generationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            generation = GenerationEndpointConfiguration(
                providerKind: generationKind,
                endpointPath: endpoint.isEmpty ? nil : endpoint,
                modelIDs: Self.parseIDLines(generationModelIDsText),
                options: generationOptions
            )
        } else {
            generation = nil
        }

        var secretHeaderValues: [UUID: String] = [:]
        let headerConfigurations: [ProviderHeaderConfiguration] = try headers.map { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ProviderEditorLocalError.invalidHeaderName
            }
            if row.isSecret {
                let trimmedValue = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedValue.isEmpty {
                    secretHeaderValues[row.id] = trimmedValue
                }
                return ProviderHeaderConfiguration(id: row.id, name: name, value: nil, isSecret: true)
            }
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderHeaderConfiguration(
                id: row.id,
                name: name,
                value: value.isEmpty ? nil : value,
                isSecret: false
            )
        }

        let auth = ProviderAuthConfiguration(
            kind: authKind,
            headerName: authKind == .customHeader
                ? authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil,
            valuePrefix: {
                let trimmed = authValuePrefix
                return trimmed.isEmpty ? nil : trimmed
            }()
        )

        let profile = AIProviderProfile(
            id: profileID,
            name: name,
            baseURL: baseURL,
            enabled: enabled,
            allowInsecureHTTP: allowInsecureHTTP,
            allowCredentialRedirects: allowCredentialRedirects,
            auth: auth,
            headers: headerConfigurations,
            agent: agent,
            generation: generation,
            createdAt: createdAt,
            updatedAt: Date()
        )

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryCredential: String? = trimmedKey.isEmpty ? nil : apiKey

        return (profile, primaryCredential, secretHeaderValues)
    }

    private static func parseModelLines(_ text: String, defaultModelID: String) -> [AgentModelOption] {
        var seen = Set<String>()
        var models: [AgentModelOption] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let modelID = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { continue }
            models.append(AgentModelOption(modelID: modelID, displayName: modelID))
        }
        let defaultID = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultID.isEmpty, !seen.contains(defaultID) {
            models.insert(AgentModelOption(modelID: defaultID, displayName: defaultID), at: 0)
        }
        return models
    }

    private static func parseIDLines(_ text: String) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    private static func parseJSONObject(_ text: String, fieldName: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "{}" : trimmed
        guard let data = source.data(using: .utf8) else {
            throw ProviderEditorLocalError.invalidJSONObject(fieldName)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ProviderEditorLocalError.invalidJSONObject(fieldName)
        }
        guard let dictionary = object as? [String: Any] else {
            throw ProviderEditorLocalError.invalidJSONObject(fieldName)
        }
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            result[key] = try JSONValue(foundationValue: value)
        }
        return result
    }

    private static func encodeJSONObject(_ object: [String: JSONValue]) -> String {
        if object.isEmpty { return "{}" }
        let foundation = Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.value.foundationValue) })
        guard JSONSerialization.isValidJSONObject(foundation),
              let data = try? JSONSerialization.data(
                withJSONObject: foundation,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

private enum ProviderEditorLocalError: LocalizedError {
    case missingService
    case invalidJSONObject(String)
    case invalidHeaderName

    var errorDescription: String? {
        switch self {
        case .missingService:
            "Configure at least one Agent or Generation service."
        case .invalidJSONObject(let field):
            "\(field) must be a JSON object."
        case .invalidHeaderName:
            "Header name cannot be empty."
        }
    }
}

// MARK: - Editor sheet

private struct ProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store = AIProviderStore.shared

    @State private var draft: ProviderEditorDraft
    @State private var statusText: String?
    @State private var isWorking = false

    private let onFinished: (String?) -> Void

    init(draft: ProviderEditorDraft, onFinished: @escaping (String?) -> Void) {
        _draft = State(initialValue: draft)
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                    generalSection
                    authSection
                    agentSection
                    generationSection
                    headersSection
                    if draft.showsInsecureHTTPWarning {
                        insecureWarning
                    }
                    if let statusText {
                        Text(statusText)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(statusForeground(statusText))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AppTheme.Spacing.xlXxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            Divider().overlay(AppTheme.Border.subtleColor)
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 520, maxHeight: 720)
        .background(AppTheme.Background.prominentColor)
        .disabled(isWorking)
    }

    private var header: some View {
        HStack {
            Text(draft.isNew ? "Add Provider" : "Edit Provider")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(isWorking)
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Test Connection") {
                testConnection()
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(isWorking)
            .help("May use a small number of provider tokens")

            Text("May use a small number of provider tokens")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            Spacer()

            Button("Save") {
                save()
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .disabled(isWorking)
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionTitle("General")
            labeledField("Name") {
                TextField("Provider name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(fieldBackground)
            }
            labeledField("Base URL") {
                TextField("https://api.example.com/v1", text: $draft.baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(fieldBackground)
            }
            Toggle("Enabled", isOn: $draft.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Toggle("Allow insecure HTTP (non-local)", isOn: $draft.allowInsecureHTTP)
                .toggleStyle(.switch)
                .controlSize(.mini)
            Toggle("Allow credentials on cross-host job URLs", isOn: $draft.allowCredentialRedirects)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Only enable this when the provider intentionally returns status or result URLs on another trusted host.")
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionTitle("Authentication")
            Picker("Auth", selection: $draft.authKind) {
                ForEach(ProviderEditorDraft.selectableAuthKinds, id: \.self) { kind in
                    Text(authLabel(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if draft.authKind == .customHeader {
                labeledField("Header name") {
                    TextField("Authorization", text: $draft.authHeaderName)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
            }

            if draft.requiresPrimaryCredential {
                labeledField("API key") {
                    SecureField(
                        draft.isNew ? "API key" : "Leave blank to keep existing key",
                        text: $draft.apiKey
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(fieldBackground)
                }
            }

            labeledField("Value prefix") {
                TextField("Bearer  or Key ", text: $draft.authValuePrefix)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(fieldBackground)
            }
            Text("Optional. Examples: “Bearer ” or “Key ”. Leave empty for none.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionTitle("Agent")
            Toggle("Enable Agent", isOn: $draft.agentEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)

            if draft.agentEnabled {
                Picker("Protocol", selection: agentProtocolBinding) {
                    ForEach(ProviderEditorDraft.selectableAgentProtocols, id: \.self) { wire in
                        Text(wire.label).tag(wire)
                    }
                }
                .pickerStyle(.menu)

                labeledField("Endpoint path") {
                    TextField("responses", text: $draft.agentEndpoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
                labeledField("Default model") {
                    TextField("model-id", text: $draft.agentDefaultModel)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
                labeledField("Models (one per line)") {
                    TextEditor(text: $draft.agentModelsText)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .frame(minHeight: 72)
                        .padding(AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
                labeledField("Max output tokens") {
                    TextField("16384", text: $draft.agentMaxOutputTokens)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
                labeledField("Additional JSON object") {
                    TextEditor(text: $draft.agentAdditionalBodyText)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .frame(minHeight: 88)
                        .padding(AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
            }
        }
    }

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionTitle("Generation")
            Toggle("Enable Generation", isOn: $draft.generationEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)

            if draft.generationEnabled {
                Picker("Kind", selection: $draft.generationKind) {
                    ForEach(ProviderEditorDraft.selectableGenerationKinds, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                labeledField("Endpoint path") {
                    TextField("optional", text: $draft.generationEndpoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
                labeledField("Model IDs (one per line)") {
                    TextEditor(text: $draft.generationModelIDsText)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .frame(minHeight: 72)
                        .padding(AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
                labeledField("Options JSON object") {
                    TextEditor(text: $draft.generationOptionsText)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .frame(minHeight: 88)
                        .padding(AppTheme.Spacing.sm)
                        .background(fieldBackground)
                }
            }
        }
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                sectionTitle("Headers")
                Spacer()
                Button("Add Header") {
                    draft.headers.append(
                        ProviderEditorDraft.HeaderDraft(id: UUID(), name: "", isSecret: false, value: "")
                    )
                }
                .buttonStyle(.capsule(.secondary, size: .small))
                .disabled(isWorking)
            }

            if draft.headers.isEmpty {
                Text("No extra headers.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                ForEach($draft.headers) { $header in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            TextField("Header name", text: $header.name)
                                .textFieldStyle(.plain)
                                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                                .padding(.horizontal, AppTheme.Spacing.md)
                                .padding(.vertical, AppTheme.Spacing.sm)
                                .background(fieldBackground)

                            Toggle("Secret", isOn: $header.isSecret)
                                .toggleStyle(.switch)
                                .controlSize(.mini)

                            Button(role: .destructive) {
                                draft.headers.removeAll { $0.id == header.id }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: AppTheme.FontSize.sm))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .help("Remove header")
                        }

                        if header.isSecret {
                            SecureField(
                                draft.isNew ? "Secret value" : "Leave blank to keep existing value",
                                text: $header.value
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.sm)
                            .background(fieldBackground)
                        } else {
                            TextField("Value", text: $header.value)
                                .textFieldStyle(.plain)
                                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                                .padding(.horizontal, AppTheme.Spacing.md)
                                .padding(.vertical, AppTheme.Spacing.sm)
                                .background(fieldBackground)
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                }
            }
        }
    }

    private var insecureWarning: some View {
        Text("Warning: This provider uses plain HTTP to a non-local host. Credentials and prompts may be transmitted in cleartext.")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Status.warningColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Status.warningColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Status.warningColor.opacity(0.45), lineWidth: AppTheme.BorderWidth.thin)
            )
    }

    private var agentProtocolBinding: Binding<AgentWireProtocol> {
        Binding(
            get: { draft.agentProtocol },
            set: { newValue in
                let oldValue = draft.agentProtocol
                guard oldValue != newValue else { return }
                draft.applyAgentProtocolChange(from: oldValue, to: newValue)
                draft.agentProtocol = newValue
            }
        )
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(AppTheme.Opacity.muted))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            content()
        }
    }

    private func authLabel(_ kind: ProviderAuthKind) -> String {
        switch kind {
        case .bearer: "Bearer"
        case .xAPIKey: "x-api-key"
        case .customHeader: "Custom header"
        case .none: "None"
        case .palmierManaged: "Palmier Cloud"
        }
    }

    private func statusForeground(_ text: String) -> Color {
        let lowered = text.lowercased()
        if lowered.contains("fail")
            || lowered.contains("error")
            || lowered.contains("unable")
            || lowered.contains("invalid")
            || lowered.contains("missing") {
            return AppTheme.Status.errorColor
        }
        return AppTheme.Text.secondaryColor
    }

    private func save() {
        isWorking = true
        statusText = nil
        Task {
            do {
                let built = try draft.makeProfile()
                try await store.saveProfile(
                    built.profile,
                    primaryCredential: built.primaryCredential,
                    secretHeaderValues: built.secretHeaderValues
                )
                onFinished("Saved “\(built.profile.name)”.")
                isWorking = false
                dismiss()
            } catch {
                statusText = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func testConnection() {
        isWorking = true
        statusText = nil
        Task {
            do {
                let built = try draft.makeProfile()
                let runtime = try await store.runtimeProfile(
                    for: built.profile,
                    primaryCredentialOverride: built.primaryCredential,
                    secretHeaderOverrides: built.secretHeaderValues
                )
                let result = try await AIProviderConnectionTester.test(runtimeProfile: runtime)
                statusText = result.message
            } catch {
                statusText = error.localizedDescription
            }
            isWorking = false
        }
    }
}
