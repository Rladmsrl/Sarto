import SartoProtocol
import PrismDesign
import SwiftUI

/// Obsidian Prism glass sheet to start a new session with any Sarto coding agent.
public struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    @Bindable var state: SartoState
    @State private var selectedAgentID: String = "antigravity"
    @State private var selectedProjectPath: String = ""
    @State private var promptText: String = ""
    @State private var isCreating: Bool = false

    public init(state: SartoState) {
        self.state = state
    }

    public var body: some View {
        let agentsList = state.selectableAgents.isEmpty
            ? [AgentStatusInfo(id: "antigravity", name: "Google Antigravity", state: "available", version: "1.5.14"),
               AgentStatusInfo(id: "claude-code", name: "Claude Code", state: "ready"),
               AgentStatusInfo(id: "codex", name: "Codex CLI", state: "ready"),
               AgentStatusInfo(id: "pi", name: "Pi RPC", state: "ready")]
            : Array(state.selectableAgents.prefix(8))

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(l10n.tr("newSession.title"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                Button(l10n.tr("newSession.cancel")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .disabled(isCreating)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.tr("newSession.selectAgent"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(agentsList) { agent in
                        let active = selectedAgentID == agent.id
                        Button {
                            selectedAgentID = agent.id
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(active ? tokens.primary : tokens.placeholder)
                                    .frame(width: 6, height: 6)
                                Text(agent.name)
                                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? tokens.foreground : tokens.secondaryForeground)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(active ? tokens.primarySoft : tokens.surface1))
                            .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(active ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(isCreating)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.tr("newSession.projectPath"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                TextField(SartoState.defaultWorkspacePath, text: $selectedProjectPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
                    .disabled(isCreating)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.tr("newSession.initialPrompt"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                TextField(l10n.tr("newSession.promptPlaceholder"), text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...6)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.codeBackground))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rSM).strokeBorder(tokens.borderEtched, lineWidth: 1))
                    .disabled(isCreating)
            }

            HStack {
                Spacer()
                Button(action: submit) {
                    Text(l10n.tr("newSession.launch"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.palette.isDark ? Color(hex: 0x0E0F14) : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(tokens.palette.isDark ? Color(hex: 0xF2F3F7) : Color(hex: 0x14151B)))
                        .opacity(isCreating ? 0.6 : 1.0)
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
            }
        }
        .padding(22)
        .background(tokens.background)
        .onAppear {
            selectedAgentID = state.selectedAgentID
            if let activeProject = state.selectedSessionSummary?.projectPath, !activeProject.isEmpty {
                selectedProjectPath = activeProject
            } else if let firstProject = state.projects.first?.path, !firstProject.isEmpty {
                selectedProjectPath = firstProject
            } else if selectedProjectPath.isEmpty {
                selectedProjectPath = SartoState.defaultWorkspacePath
            }
        }
        #if os(macOS)
        .frame(width: 460)
        #endif
    }

    private func submit() {
        guard !isCreating else { return }
        isCreating = true
        let proj = selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { isCreating = false }
            await state.createSession(
                agentId: selectedAgentID,
                projectPath: proj.isEmpty ? nil : proj,
                prompt: promptText
            )
            dismiss()
        }
    }
}
