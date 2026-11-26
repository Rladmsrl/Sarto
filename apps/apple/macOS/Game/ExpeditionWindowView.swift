import PrismDesign
import SartoProtocol
import SwiftUI

/// Native macOS Expedition window: live battlefield, manual Ship it! ultimate, Boss challenges,
/// Workshop card crafting & 3-to-1 synthesis, Hackathon roguelike runs, Agent weapon showcase
/// and Nightly Build reports.
struct ExpeditionWindowView: View {
    enum SectionTab: String, CaseIterable, Identifiable {
        case loadout
        case hackathon
        case weapons

        var id: String { rawValue }
    }

    var appState: SartoState
    var store: GameStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: SectionTab = .loadout
    @State private var selectedCards: Set<String> = []
    @State private var targetedSchool: String = "review"

    private var tokens: PrismTokens { appState.tokens }
    private var l10n: PrismL10n { appState.l10n }

    var body: some View {
        Group {
            if let state = store.state, store.status?.enabled == true {
                content(state)
            } else {
                emptyView
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(tokens.background)
        .preferredColorScheme(appState.palette.colorScheme)
        .environment(\.prismTokens, tokens)
        .environment(\.prismL10n, l10n)
        .environment(\.locale, appState.language.resolvedLocale)
        .onAppear { store.setSurfaceVisible(true) }
        .onDisappear { store.setSurfaceVisible(false) }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28))
                .foregroundStyle(tokens.prismIris)
            Text(l10n.tr("game.empty.title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(store.status?.lastError ?? l10n.tr("game.empty.subtitle"))
                .font(.system(size: 12.5))
                .foregroundStyle(tokens.secondaryForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func content(_ state: GameStateInfo) -> some View {
        VStack(spacing: 0) {
            topHeroBar(state)
            if let err = store.lastCommandError {
                errorBanner(err)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    arenaCard(state)
                    if let offer = state.offers.first {
                        offerCard(offer)
                    }
                    if let report = store.lastClaimedReport {
                        claimedReportBanner(report)
                    }
                    tabPicker(state)
                    switch tab {
                    case .loadout:
                        loadoutSection(state)
                    case .hackathon:
                        hackathonSection(state)
                    case .weapons:
                        weaponsAndReportSection(state)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Top Hero Bar

    private func topHeroBar(_ state: GameStateInfo) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.prismIris)
                Text(state.heroName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(state.version)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.prismAmber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.prismAmber.opacity(0.14)))
            }

            // XP Progress
            HStack(spacing: 6) {
                GeometryReader { geo in
                    let pct = min(1, max(0, CGFloat(state.xp) / CGFloat(max(1, state.xpNext))))
                    ZStack(alignment: .leading) {
                        Capsule().fill(tokens.surface3)
                        Capsule()
                            .fill(tokens.prismCobalt)
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(width: 96, height: 6)
                Text("XP \(state.xp)/\(state.xpNext)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                statPill(label: l10n.tr("game.stat.power"), value: "\(state.power)", accent: tokens.prismCobalt)
                    .help(powerBreakdownText(state))
                statPill(label: l10n.tr("game.stat.compute"), value: "\(state.compute)", accent: tokens.prismAmber)
                HStack(spacing: 5) {
                    Circle()
                        .fill(accountStateColor(state.accountState))
                        .frame(width: 7, height: 7)
                    Text(l10n.tr("game.state.\(state.accountState)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(tokens.surface2))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tokens.surface1)
        .overlay(alignment: .bottom) { Rectangle().fill(tokens.borderEtched).frame(height: 1) }
    }

    private func statPill(label: String, value: String, accent: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tokens.surface2))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tokens.danger)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
            Spacer()
            Button(l10n.tr("game.action.dismiss")) { store.clearError() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.secondaryForeground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(tokens.dangerSoft)
    }

    // MARK: - Live Arena & Ship it! Ultimate

    private func arenaCard(_ state: GameStateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(stageHeaderTitle(state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                if let weapon = state.mainWeapon {
                    Text("· \(weapon)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(tokens.prismIris)
                }
                Spacer()
                Text(stageSubtitle(state))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
            }

            arenaCanvas(state)
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.borderEtched, lineWidth: 1)
                )

            // Ultimate Bar + Boss Challenge Controls
            HStack(spacing: 10) {
                Text("Ship it!")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.prismAmber)

                GeometryReader { geo in
                    let pct = min(1, max(0, CGFloat(store.liveUlt) / CGFloat(max(1, state.ultMax))))
                    ZStack(alignment: .leading) {
                        Capsule().fill(tokens.surface3)
                        Capsule()
                            .fill(store.liveUlt >= state.ultMax ? tokens.prismAmber : tokens.prismCobalt)
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(width: 120, height: 7)

                Text("\(store.liveUlt)/\(state.ultMax)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()

                Toggle(isOn: Binding(
                    get: { state.ultManual },
                    set: { manual in Task { await store.send("setUltMode", args: ["manual": .bool(manual)]) } }
                )) {
                    Text(l10n.tr("game.ult.manual"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                }
                .toggleStyle(.checkbox)
                .disabled(store.busy)

                actionButton(
                    title: "Ship it!",
                    prominent: store.liveUlt >= state.ultMax && store.fightingEliteOrBoss,
                    disabled: store.busy || store.liveUlt < state.ultMax || !store.fightingEliteOrBoss
                ) {
                    Task { await store.send("castUlt") }
                }

                Spacer()

                actionButton(
                    title: state.boss != nil
                        ? l10n.tr("game.boss.inProgress")
                        : l10n.tr("game.boss.challenge", "\(state.chapter)", "\(state.stageRequired)"),
                    prominent: state.bossReady && state.boss == nil,
                    disabled: store.busy || !state.bossReady || state.boss != nil
                ) {
                    Task { await store.send("challengeBoss") }
                }
            }

            // Stage Track (1..10)
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { idx in
                    let done = idx < state.stage
                    let current = idx == state.stage
                    Text(idx == 10 ? "Boss" : (idx == 5 ? "\(state.chapter)-5★" : "\(state.chapter)-\(idx)"))
                        .font(.system(size: 10, weight: current ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(current ? tokens.onPrimary : (done ? tokens.success : tokens.mutedForeground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(current ? tokens.primary : (done ? tokens.successSoft : tokens.surface2))
                        )
                }
            }

            Text(powerBreakdownText(state))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground)

            if let last = state.lastBoss, !last.won {
                bossAdviceBox(last)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    @ViewBuilder
    private func arenaCanvas(_ state: GameStateInfo) -> some View {
        let fps = PrismEnergyPolicy.capped(
            PrismEnergyPolicy.framesPerSecond(
                for: .streaming,
                surface: .fullWindow,
                displayMaxFPS: 60,
                conditions: PrismEnergyMonitor.shared.conditions
            ),
            requestedFPS: 30
        )
        let still = reduceMotion || fps <= 0
        TimelineView(.animation(minimumInterval: 1.0 / Double(max(1, still ? 4 : fps)), paused: false)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                GameArenaRenderer.draw(
                    context: &context,
                    size: size,
                    display: store.frame(at: timeline.date),
                    weaponHarness: state.mainWeapon,
                    tokens: tokens,
                    l10n: l10n,
                    now: timeline.date,
                    still: still,
                    compact: false
                )
            }
        }
        .background(tokens.surface2)
    }

    private func bossAdviceBox(_ result: GameBossResultInfo) -> some View {
        let pct = Int((Double(result.damageDealt) / Double(max(1, result.bossHp)) * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            Text(l10n.tr("game.boss.lastFailed", "\(pct)", "\(result.power)", "\(result.required)"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tokens.prismAmber)
            ForEach(result.advice, id: \.self) { key in
                Text("• \(l10n.tr("game.\(key)"))")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.secondaryForeground)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tokens.warningSoft))
    }

    // MARK: - Pending Milestone Offer

    private func offerCard(_ offer: GameOfferInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(tokens.prismAmber)
                Text(l10n.tr("game.offer.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(Array(offer.options.enumerated()), id: \.element.id) { idx, perk in
                    perkChoiceButton(perk: perk, recommended: idx == offer.recommended) {
                        Task {
                            await store.send("pick", args: [
                                "offerId": .string(offer.id),
                                "option": .number(Double(idx))
                            ])
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.prismAmber.opacity(0.55), lineWidth: 1))
    }

    // MARK: - Section Tabs

    private func tabPicker(_ state: GameStateInfo) -> some View {
        HStack(spacing: 6) {
            ForEach(SectionTab.allCases) { item in
                let active = tab == item
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 5) {
                        Text(tabTitle(item, state: state))
                            .font(.system(size: 12, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? tokens.onPrimary : tokens.secondaryForeground)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(active ? tokens.primary : tokens.surface2))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func tabTitle(_ item: SectionTab, state: GameStateInfo) -> String {
        switch item {
        case .loadout:
            return "\(l10n.tr("game.tab.loadout")) (\(state.cards.count))"
        case .hackathon:
            return state.hackathon.run != nil
                ? "\(l10n.tr("game.tab.hackathon")) ●"
                : "\(l10n.tr("game.tab.hackathon")) (\(state.hackathon.runsToday)/\(state.hackathon.fullRuns))"
        case .weapons:
            return "\(l10n.tr("game.tab.weapons")) (\(state.weapons.count))"
        }
    }

    // MARK: - Tab 1: Loadout & Workshop

    private func loadoutSection(_ state: GameStateInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Side Slots + Workshop Craft Controls
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(l10n.tr("game.loadout.slotsTitle"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Spacer()
                    Text(materialsSummary(state.materials))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.secondaryForeground)
                }

                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { idx in
                        slotButton(state: state, slot: idx)
                    }
                    Spacer()
                }

                Divider().overlay(tokens.borderEtched)

                // Workshop Crafting & Merging Bar
                HStack(spacing: 8) {
                    actionButton(
                        title: l10n.tr("game.craft.random", "\(state.craftRandomCost)"),
                        prominent: state.compute >= state.craftRandomCost,
                        disabled: store.busy || state.compute < state.craftRandomCost
                    ) {
                        Task { await store.send("craftCard") }
                    }

                    Picker("", selection: $targetedSchool) {
                        ForEach(["review", "search", "rewrite", "orchestrate"], id: \.self) { sch in
                            Text(schoolName(sch)).tag(sch)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    actionButton(
                        title: l10n.tr("game.craft.targeted", "\(state.craftTargetedCost)"),
                        prominent: false,
                        disabled: store.busy || state.compute < state.craftTargetedCost
                    ) {
                        Task { await store.send("craftCard", args: ["school": .string(targetedSchool)]) }
                    }

                    Spacer()

                    actionButton(
                        title: l10n.tr("game.merge.action", "\(selectedCards.count)"),
                        prominent: selectedCards.count == 3,
                        disabled: store.busy || selectedCards.count != 3
                    ) {
                        let ids = Array(selectedCards)
                        Task {
                            if await store.send("merge", args: ["cardIds": .array(ids.map(JSONValue.string))]) {
                                selectedCards.removeAll()
                            }
                        }
                    }
                }

                // Card Inventory
                Text(l10n.tr("game.loadout.cardsHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)

                let validIds = Set(state.cards.map(\.id))
                let equippedIds = Set(state.slots.compactMap { $0?.id })
                if state.cards.isEmpty {
                    Text(l10n.tr("game.loadout.noCards"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.vertical, 6)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                        ForEach(state.cards) { card in
                            let isEquipped = equippedIds.contains(card.id)
                            let isSelected = selectedCards.contains(card.id) && validIds.contains(card.id)
                            cardTile(
                                card: card,
                                equipped: isEquipped,
                                selected: isSelected,
                                onEquip: {
                                    if let free = (0..<state.slotCount).first(where: { idx in
                                        idx >= state.slots.count || state.slots[idx] == nil
                                    }) {
                                        Task {
                                            await store.send("equipCard", args: [
                                                "cardId": .string(card.id),
                                                "slot": .number(Double(free))
                                            ])
                                        }
                                    } else {
                                        toggleCardSelection(card.id, validIds: validIds)
                                    }
                                },
                                onSelectMerge: {
                                    toggleCardSelection(card.id, validIds: validIds)
                                }
                            )
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))

            // Sets & Active Milestones
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l10n.tr("game.build.setsAndPerks"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Spacer()
                    policyMenu(state)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], spacing: 6) {
                    ForEach(state.sets) { set in
                        HStack(spacing: 4) {
                            Text(set.name)
                                .font(.system(size: 11, weight: set.active ? .bold : .regular))
                            Spacer(minLength: 2)
                            Text("\(min(3, set.count))/3")
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        .foregroundStyle(set.active ? tokens.prismAmber : tokens.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(set.active ? tokens.prismAmber.opacity(0.14) : tokens.surface2)
                        )
                        .help(set.desc)
                    }
                }
                if !state.perks.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(state.perks) { p in
                            Text(p.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tokens.prismIris)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(tokens.prismIris.opacity(0.13)))
                                .help(p.desc)
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
        }
    }

    private func slotButton(state: GameStateInfo, slot: Int) -> some View {
        let locked = slot >= state.slotCount
        let card: GameCardInfo? = slot < state.slots.count ? state.slots[slot] : nil
        return Button {
            guard !locked, card != nil else { return }
            Task { await store.send("unequipCard", args: ["slot": .number(Double(slot))]) }
        } label: {
            VStack(spacing: 3) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                    Text(slot == 1 ? l10n.tr("game.slot.unlock5") : l10n.tr("game.slot.unlock8"))
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.mutedForeground)
                } else if let card {
                    Text(schoolName(card.school))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(schoolColor(card.school))
                    Text("T\(card.tier)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(tokens.foreground)
                } else {
                    Text(l10n.tr("game.slot.empty", "\(slot + 1)"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .frame(width: 112, height: 52)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tokens.surface2))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(card != nil ? schoolColor(card!.school).opacity(0.6) : tokens.borderEtched, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(locked || card == nil || store.busy)
    }

    private func cardTile(
        card: GameCardInfo,
        equipped: Bool,
        selected: Bool,
        onEquip: @escaping () -> Void,
        onSelectMerge: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: onEquip) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(schoolColor(card.school))
                        .frame(width: 6, height: 6)
                    Text(schoolName(card.school))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.foreground)
                    Text("T\(card.tier)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(tokens.prismAmber)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onSelectMerge) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? tokens.prismCobalt : tokens.mutedForeground)
            }
            .buttonStyle(.plain)
            .help(l10n.tr("game.merge.selectHelp"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .opacity(equipped ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? tokens.primarySoft : tokens.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? tokens.primary : tokens.borderEtched, lineWidth: 1)
        )
    }

    private func toggleCardSelection(_ id: String, validIds: Set<String>) {
        selectedCards = selectedCards.intersection(validIds)
        if selectedCards.contains(id) {
            selectedCards.remove(id)
        } else if selectedCards.count < 3 {
            selectedCards.insert(id)
        }
    }

    private func policyMenu(_ state: GameStateInfo) -> some View {
        let current = state.policyKind == "recommended"
            ? "recommended"
            : "\(state.policyKind):\(state.policyValue ?? "review")"
        return Menu {
            Button(l10n.tr("game.policy.recommended")) {
                Task { await store.send("setPolicy", args: ["policy": .object(["kind": .string("recommended")])]) }
            }
            ForEach(["review", "search", "rewrite", "orchestrate"], id: \.self) { sch in
                Button("\(l10n.tr("game.policy.prefer")) \(schoolName(sch))") {
                    Task {
                        await store.send("setPolicy", args: [
                            "policy": .object(["kind": .string("school"), "value": .string(sch)])
                        ])
                    }
                }
            }
        } label: {
            Text("\(l10n.tr("game.policy.label")): \(current == "recommended" ? l10n.tr("game.policy.recommended") : current)")
                .font(.system(size: 11))
                .foregroundStyle(tokens.secondaryForeground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Tab 2: Hackathon Roguelike

    private func hackathonSection(_ state: GameStateInfo) -> some View {
        let h = state.hackathon
        return VStack(alignment: .leading, spacing: 12) {
            if let run = h.run {
                activeRunView(run)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(l10n.tr("game.hack.subtitle", "\(h.runsToday)", "\(h.fullRuns)"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.secondaryForeground)
                    if let mem = h.memory {
                        Text("\(l10n.tr("game.hack.memory")): \(mem.name) — \(mem.desc)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.prismIris)
                    }
                    HStack(spacing: 8) {
                        ForEach(h.envs) { env in
                            actionButton(
                                title: "P\(env.id) \(env.name)\(env.unlocked ? "" : " 🔒")",
                                prominent: env.unlocked && env.id == 0,
                                disabled: store.busy || !env.unlocked
                            ) {
                                Task { await store.send("runStart", args: ["env": .number(Double(env.id))]) }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
            }
        }
    }

    private func activeRunView(_ run: GameRunInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("P\(run.env) \(run.envName)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(tokens.prismIris)
                Text("· \(l10n.tr("game.hack.step", "\(run.leg + 1)", "\(run.legs)", "\(run.step + 1)", "\(run.steps)"))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
                Spacer()
                statPill(label: l10n.tr("game.hack.credits"), value: "\(run.credits)", accent: tokens.prismAmber)
                statPill(label: l10n.tr("game.stat.power"), value: "\(run.power)", accent: tokens.prismCobalt)
                if run.status != "ended" {
                    actionButton(title: l10n.tr("game.hack.abandon"), prominent: false, disabled: store.busy) {
                        Task { await store.send("runAbandon") }
                    }
                }
            }

            if !run.perks.isEmpty || !run.curses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(run.perks) { p in
                            Text(p.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tokens.prismCobalt)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(tokens.primarySoft))
                                .help(p.desc)
                        }
                        ForEach(run.curses) { c in
                            Text("⚠ \(c.name)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(tokens.danger)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(tokens.dangerSoft))
                                .help(c.desc)
                        }
                    }
                }
            }

            Divider().overlay(tokens.borderEtched)

            switch run.status {
            case "choosing":
                HStack(spacing: 8) {
                    Text(l10n.tr("game.hack.chooseRoad"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.secondaryForeground)
                    ForEach(Array(run.paths.enumerated()), id: \.offset) { idx, node in
                        actionButton(
                            title: l10n.tr("game.node.\(node)"),
                            prominent: true,
                            disabled: store.busy
                        ) {
                            Task { await store.send("runChoose", args: ["option": .number(Double(idx))]) }
                        }
                    }
                }

            case "fighting":
                HStack(spacing: 10) {
                    if let rem = run.fightRemaining, let tot = run.fightTotal {
                        let leftSec = run.fightDeadline.map { max(0, Int((($0 - store.estimatedServerNow()) / 1000).rounded(.up))) } ?? 0
                        Text(l10n.tr("game.hack.waveStatus", "\(rem)", "\(tot)", "\(leftSec)"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(tokens.foreground)
                    } else if let boss = run.boss {
                        Text("Boss: \(boss.hp)/\(boss.maxHp)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(tokens.danger)
                    }
                    Spacer()
                    actionButton(
                        title: l10n.tr("game.hack.skipFight"),
                        prominent: true,
                        disabled: store.busy
                    ) {
                        Task { await store.send("runSkipFight") }
                    }
                }

            case "reward":
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Array(run.rewardOptions.enumerated()), id: \.offset) { idx, perk in
                            perkChoiceButton(perk: perk, recommended: false) {
                                Task { await store.send("runPick", args: ["option": .number(Double(idx))]) }
                            }
                        }
                    }
                    actionButton(
                        title: l10n.tr("game.hack.skipReward", "\(run.skipCredits)"),
                        prominent: false,
                        disabled: store.busy
                    ) {
                        Task { await store.send("runPick", args: ["option": .number(Double(run.rewardOptions.count))]) }
                    }
                }

            case "market":
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(run.market) { item in
                            if item.kind == "remove" {
                                actionButton(
                                    title: item.sold
                                        ? l10n.tr("game.market.sold")
                                        : l10n.tr("game.market.remove", "\(item.price)"),
                                    prominent: false,
                                    disabled: store.busy || item.sold || run.credits < item.price || run.perks.isEmpty
                                ) {
                                    Task { await store.send("runBuy", args: ["item": .number(Double(item.id))]) }
                                }
                            } else if let perk = item.perk {
                                perkChoiceButton(
                                    perk: perk,
                                    recommended: false,
                                    priceTag: item.sold ? l10n.tr("game.market.sold") : "\(item.price)",
                                    disabled: item.sold || run.credits < item.price
                                ) {
                                    Task { await store.send("runBuy", args: ["item": .number(Double(item.id))]) }
                                }
                            }
                        }
                    }
                    actionButton(title: l10n.tr("game.market.leave"), prominent: false, disabled: store.busy) {
                        Task { await store.send("runCoffee", args: ["action": .string("leave")]) }
                    }
                }

            case "coffee":
                HStack(spacing: 8) {
                    actionButton(
                        title: l10n.tr("game.coffee.payDebt"),
                        prominent: !run.curses.isEmpty && run.credits >= 60,
                        disabled: store.busy || run.curses.isEmpty || run.credits < 60
                    ) {
                        Task { await store.send("runCoffee", args: ["action": .string("payDebt")]) }
                    }
                    actionButton(
                        title: l10n.tr("game.coffee.espresso"),
                        prominent: true,
                        disabled: store.busy
                    ) {
                        Task { await store.send("runCoffee", args: ["action": .string("espresso")]) }
                    }
                }

            case "ended":
                if let r = run.result {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.won ? l10n.tr("game.hack.won") : l10n.tr("game.hack.lost"))
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(r.won ? tokens.success : tokens.prismAmber)
                        Text(l10n.tr("game.hack.summary", "\(r.nodesCleared)", "\(r.compute)"))
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.secondaryForeground)
                        Text(l10n.tr("game.hack.pickMemory"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                        HStack(spacing: 6) {
                            ForEach(r.memoryChoices) { p in
                                actionButton(title: p.name, prominent: true, disabled: store.busy) {
                                    Task { await store.send("runMemory", args: ["perkId": .string(p.id)]) }
                                }
                            }
                            actionButton(title: l10n.tr("game.hack.noMemory"), prominent: false, disabled: store.busy) {
                                Task { await store.send("runMemory", args: ["perkId": .null]) }
                            }
                        }
                    }
                }

            default:
                EmptyView()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    // MARK: - Tab 3: Weapons & Nightly Report

    private func weaponsAndReportSection(_ state: GameStateInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.tr("game.weapons.title"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text(l10n.tr("game.weapons.fairnessHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)

                if state.weapons.isEmpty {
                    Text(l10n.tr("game.weapons.empty"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .padding(.vertical, 4)
                } else {
                    ForEach(state.weapons) { w in
                        HStack(spacing: 10) {
                            let (_, color) = GameArenaRenderer.visual(for: w.harness, tokens: tokens)
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text("\(w.harness) · Lv.\(w.level)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(tokens.foreground)
                            Text(l10n.tr("game.weapons.minutes", "\(w.minutes)", "\(w.todayMinutes)"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tokens.secondaryForeground)
                            Spacer()
                            if w.harness == state.mainWeapon {
                                Text(l10n.tr("game.weapons.equipped"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(tokens.success)
                            } else {
                                actionButton(title: l10n.tr("game.weapons.equip"), prominent: false, disabled: store.busy) {
                                    Task { await store.send("equipMain", args: ["harness": .string(w.harness)]) }
                                }
                            }
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tokens.surface2))
                    }
                }

                if !state.titles.isEmpty {
                    HStack(spacing: 6) {
                        Text(l10n.tr("game.titles.label"))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                        ForEach(state.titles, id: \.self) { t in
                            Text(t)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(tokens.prismAmber)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tokens.prismAmber.opacity(0.14)))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))

            // Pending Nightly Build Report
            let r = state.pendingReport
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l10n.tr("game.report.title"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Spacer()
                    actionButton(
                        title: l10n.tr("game.report.claim"),
                        prominent: r.xp > 0 || r.compute > 0 || r.kills > 0,
                        disabled: store.busy
                    ) {
                        Task { await store.send("claim") }
                    }
                }
                Text(l10n.tr("game.report.summary", "\(r.xp)", "\(r.bonusXp)", "\(r.compute)", "\(r.kills)", "\(r.stagesCleared)"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tokens.surface1))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
        }
    }

    private func claimedReportBanner(_ r: GameReportInfo) -> some View {
        HStack {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(tokens.success)
            Text(l10n.tr("game.report.claimed", "\(r.xp)", "\(r.compute)", "\(r.kills)"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
            Spacer()
            Button(l10n.tr("game.action.dismiss")) { store.dismissClaimedReport() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(tokens.secondaryForeground)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tokens.successSoft))
    }

    // MARK: - Reusable Controls & Formatters

    private func perkChoiceButton(
        perk: GamePerkInfo,
        recommended: Bool,
        priceTag: String? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(perk.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tokens.foreground)
                    Spacer()
                    if recommended {
                        Text("★")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tokens.prismAmber)
                    }
                    if let priceTag {
                        Text(priceTag)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(tokens.prismAmber)
                    }
                }
                Text("\(schoolName(perk.school)) · \(perk.rarity)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(schoolColor(perk.school))
                Text(perk.desc)
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(2)
                if let curse = perk.curse {
                    Text("⚠ \(curse.name): \(curse.desc)")
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.danger)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tokens.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tokens.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(store.busy || disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func actionButton(
        title: String,
        prominent: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? tokens.onPrimary : tokens.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(prominent ? tokens.primary : tokens.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(prominent ? Color.clear : tokens.border, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func stageHeaderTitle(_ state: GameStateInfo) -> String {
        if state.runStatus == "fighting" { return l10n.tr("game.strip.hackathon") }
        if state.bossReady { return l10n.tr("game.stage.bossTitle", "\(state.chapter)") }
        return l10n.tr("game.stage.title", "\(state.chapter)", "\(state.chapter)-\(state.stage)")
    }

    private func stageSubtitle(_ state: GameStateInfo) -> String {
        if state.bossReady { return l10n.tr("game.stage.bossReq", "\(state.stageRequired)") }
        return "\(state.kills)/\(state.killsNeeded) · \(l10n.tr("game.stage.req", "\(state.stageRequired)"))"
    }

    private func powerBreakdownText(_ state: GameStateInfo) -> String {
        let prof = String(format: "%.2f", 1 + state.proficiencyBonus)
        let cards = String(format: "%.2f", 1 + state.cardsBonus)
        let syn = String(format: "%.2f", 1 + state.synergyBonus)
        return l10n.tr("game.power.breakdown", "\(state.basePower)", prof, cards, syn, "\(state.power)")
    }

    private func materialsSummary(_ m: [String: Int]) -> String {
        ["log", "index", "patch", "pipeline"]
            .map { "\(l10n.tr("game.mat.\($0)")) \(m[$0] ?? 0)" }
            .joined(separator: " · ")
    }

    private func schoolName(_ key: String) -> String {
        l10n.tr("game.school.\(key)")
    }

    private func schoolColor(_ key: String) -> Color {
        switch key {
        case "review": tokens.prismAmber
        case "search": tokens.prismCobalt
        case "rewrite": tokens.prismCoral
        default: tokens.prismIris
        }
    }

    private func accountStateColor(_ value: String) -> Color {
        switch value {
        case "active": tokens.success
        case "inactive": tokens.warning
        default: tokens.mutedForeground
        }
    }
}
