import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var providerStore = AIProviderStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "AI Chat") {
                providerSummary
            }
            SettingsSection(title: "Integrations") {
                mcpSection
            }
        }
    }

    private var providerSummary: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if let profile = providerStore.activeAgentProfile, let configuration = profile.agent {
                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(profile.name)
                                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Text(configuration.wireProtocol.label)
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xxs)
                                .background(
                                    Capsule().fill(Color.white.opacity(AppTheme.Opacity.subtle))
                                )
                        }
                        Text("Model: \(configuration.defaultModelID)")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Text(profile.isManagedPalmier ? "Managed by Palmier Cloud" : credentialStatus(profile))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(
                                profile.isManagedPalmier || providerStore.hasCredential(for: profile)
                                    ? AppTheme.Status.successColor
                                    : AppTheme.Status.warningColor
                            )
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    Button("Manage Providers") {
                        SettingsWindowController.shared.show(tab: .providers)
                    }
                    .buttonStyle(.capsule(.secondary))
                }
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    Text("No Agent provider is configured.")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Choose OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, Palmier Cloud, or a compatible gateway with a custom Base URL.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Configure AI Provider") {
                        SettingsWindowController.shared.show(tab: .providers)
                    }
                    .buttonStyle(.capsule(.prominent))
                }
            }
        }
    }

    private func credentialStatus(_ profile: AIProviderProfile) -> String {
        providerStore.hasCredential(for: profile)
            ? "Credentials stored in macOS Keychain"
            : "Credentials required"
    }

    // MARK: - MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .pointerStyle(.link)
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xxs) {
                        Text("Running on")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("MCP Server")
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
