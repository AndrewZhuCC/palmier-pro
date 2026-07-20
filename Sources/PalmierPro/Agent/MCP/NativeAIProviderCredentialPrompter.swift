import AppKit

struct NativeAIProviderCredentialPrompter: AIProviderCredentialPrompting {
    func requestCredentials(
        _ request: AIProviderCredentialPromptRequest
    ) async throws -> AIProviderCredentialPromptOutcome {
        try await MainActor.run {
            try Self.present(request)
        }
    }

    @MainActor
    private static func present(
        _ request: AIProviderCredentialPromptRequest
    ) throws -> AIProviderCredentialPromptOutcome {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Palmier Pro AI Provider Credentials"
        alert.informativeText = """
        An MCP client requested API credentials for “\(request.providerName)” at:
        \(request.providerBaseURL)

        Only enter credentials issued for this AI provider. Never enter your macOS login password or a personal account password. Values are saved directly to the macOS Keychain and are never returned through MCP.
        """
        alert.addButton(withTitle: "Save to Keychain")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        var controls: [(field: AIProviderCredentialPromptField, input: NSSecureTextField)] = []
        for field in request.fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            let input = NSSecureTextField()
            input.placeholderString = "Required"
            input.widthAnchor.constraint(equalToConstant: 420).isActive = true

            let row = NSStackView(views: [label, input])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 5
            stack.addArrangedSubview(row)
            controls.append((field, input))
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 420),
        ])
        alert.accessoryView = container
        alert.window.initialFirstResponder = controls.first?.input

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .cancelled
        }

        var values: [AIProviderCredentialTarget: String] = [:]
        for control in controls {
            let value = control.input.stringValue
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderCredentialPromptError.invalidResponse
            }
            do {
                try AIProviderEndpoint.validateHeaderValue(
                    value,
                    name: control.field.validationName
                )
            } catch {
                throw AIProviderCredentialPromptError.invalidResponse
            }
            values[control.field.target] = value
        }
        return .accepted(values)
    }
}
