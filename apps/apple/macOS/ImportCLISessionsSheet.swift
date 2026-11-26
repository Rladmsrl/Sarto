import SartoProtocol
import PrismDesign
import SwiftUI

/// External CLI Session Import Sheet (`agents.listSessions` + `sessions.import`):
/// Scans sessions run outside Sarto (Claude Code, Codex, OpenCode, Pi, etc.) for a chosen
/// project folder and imports them directly (or as a safe fork if still held open in a terminal).
struct ImportCLISessionsSheet: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @Bindable var state: SartoState

    @State private var selectedProjectPath: String = ""
    @State private var selectedAgentId: String = ""
    @State private var sessions: [ImportableSessionInfo] = []
    @State private var nextCursor: String? = nil
    @State private var isLoading: Bool = false
    @State private var importingID: String? = nil
    @State private var errorMessage: String? = nil
    @State private var hoveredID: String? = nil

    private var importableAgents: [AgentStatusInfo] {
        let live = state.selectableAgents.filter { $0.id != "fake-agent" }
        let capable = live.filter { $0.capabilities?.listSessions == true }
        return capable.isEmpty ? live : capable
    }

    private var availableProjects: [ProjectInfo] {
        if !state.projects.isEmpty { return state.projects }
        let fallback = state.selectedSessionSummary?.projectPath ?? state.workspace.activeProjectPath
        if fallback.isEmpty { return [] }
        return [ProjectInfo(path: fallback, name: URL(fileURLWithPath: fallback).lastPathComponent)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.tr("importCli.title"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Text(l10n.tr("importCli.subtitle"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(tokens.hoverWash))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(tokens.surface1)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            // Filter controls (Project + Agent + Refresh)
            HStack(spacing: 10) {
                Picker(l10n.tr("importCli.project"), selection: $selectedProjectPath) {
                    ForEach(availableProjects) { project in
                        Text(project.name).tag(project.path)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 230)

                Picker(l10n.tr("importCli.agent"), selection: $selectedAgentId) {
                    ForEach(importableAgents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)

                Spacer()

                Button {
                    Task { await loadSessions(reset: true) }
                } label: {
                    HStack(spacing: 5) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(l10n.tr("popover.refresh"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(tokens.hoverWash))
                }
                .buttonStyle(.plain)
                .disabled(isLoading || selectedProjectPath.isEmpty || selectedAgentId.isEmpty)
                .opacity(isLoading || selectedProjectPath.isEmpty || selectedAgentId.isEmpty ? 0.5 : 1.0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(tokens.surface1.opacity(0.5))

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.warning)
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.warning)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(tokens.warningSoft)
            }

            // Session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if isLoading && sessions.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(l10n.tr("importCli.scanning"))
                                .font(.system(size: 12))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else if sessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 24))
                                .foregroundStyle(tokens.placeholder)
                            Text(l10n.tr("importCli.empty"))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        ForEach(sessions) { item in
                            sessionRow(item)
                        }
                        if nextCursor != nil {
                            Button {
                                Task { await loadSessions(reset: false) }
                            } label: {
                                Text(l10n.tr("importCli.loadMore"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(tokens.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.hoverWash))
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    }
                }
                .padding(16)
            }
            .background(tokens.background)
        }
        .frame(width: 620, height: 480)
        .background(tokens.background)
        .preferredColorScheme(state.palette.colorScheme)
        .onAppear {
            if selectedProjectPath.isEmpty {
                selectedProjectPath = state.selectedSessionSummary?.projectPath
                    ?? availableProjects.first?.path
                    ?? ""
            }
            if selectedAgentId.isEmpty {
                selectedAgentId = importableAgents.first(where: { $0.id == state.selectedAgentID })?.id
                    ?? importableAgents.first?.id
                    ?? ""
            }
            Task { await loadSessions(reset: true) }
        }
        .onChange(of: selectedProjectPath) { _, _ in
            Task { await loadSessions(reset: true) }
        }
        .onChange(of: selectedAgentId) { _, _ in
            Task { await loadSessions(reset: true) }
        }
    }

    private func formattedRelativeTime(_ iso: String) -> String {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else {
            return iso
        }
        let rel = RelativeDateTimeFormatter()
        rel.locale = state.language.resolvedLocale
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    private func sessionRow(_ item: ImportableSessionInfo) -> some View {
        let isImporting = importingID == item.acpSessionId
        let isHovered = hoveredID == item.acpSessionId
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title?.isEmpty == false ? item.title! : item.acpSessionId)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)

                    if item.imported {
                        Text(l10n.tr("importCli.alreadyImported"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.successSoft))
                    }
                    if item.held == true {
                        Text(l10n.tr("importCli.heldInTerminal"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tokens.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.warningSoft))
                    }
                }

                HStack(spacing: 8) {
                    Text(item.acpSessionId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                        .lineLimit(1)
                    if let updated = item.updatedAt, !updated.isEmpty {
                        Text("· \(formattedRelativeTime(updated))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            } else if item.held == true {
                Button(l10n.tr("importCli.importFork")) {
                    Task { await performImport(item, fork: true) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(tokens.warningSoft))
            } else {
                Button(item.imported ? l10n.tr("importCli.openExisting") : l10n.tr("importCli.importButton")) {
                    Task { await performImport(item, fork: false) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.imported ? tokens.secondaryForeground : tokens.prismCobalt)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(item.imported ? tokens.hoverWash : tokens.prismCobalt.opacity(0.14)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(isHovered ? tokens.hoverWash : tokens.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(isHovered ? tokens.borderStrong : tokens.borderEtched, lineWidth: 1)
        )
        .onHover { inside in
            hoveredID = inside ? item.acpSessionId : (hoveredID == item.acpSessionId ? nil : hoveredID)
        }
    }

    private func loadSessions(reset: Bool) async {
        guard let host = state.activeHostSession,
              !selectedProjectPath.isEmpty,
              !selectedAgentId.isEmpty
        else { return }
        if reset {
            nextCursor = nil
            sessions = []
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await host.listAgentSessions(
                agentId: selectedAgentId,
                projectPath: selectedProjectPath,
                cursor: reset ? nil : nextCursor
            )
            if reset {
                sessions = page.sessions
            } else {
                sessions.append(contentsOf: page.sessions)
            }
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performImport(_ item: ImportableSessionInfo, fork: Bool) async {
        guard let host = state.activeHostSession else { return }
        importingID = item.acpSessionId
        errorMessage = nil
        defer { importingID = nil }
        do {
            let summary = try await host.importSession(
                agentId: selectedAgentId,
                projectPath: selectedProjectPath,
                acpSessionId: item.acpSessionId,
                fork: fork
            )
            if !state.sessions.contains(where: { $0.id == summary.id }) {
                state.sessions.insert(summary, at: 0)
            }
            dismiss()
            await state.selectSession(summary.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
