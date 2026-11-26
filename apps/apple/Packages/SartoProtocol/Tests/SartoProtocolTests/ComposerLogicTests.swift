import Foundation
import Testing
@testable import SartoProtocol

@Suite("ComposerLogic")
struct ComposerLogicTests {
    @Test("fzf path matcher scores filename and word-start matches ahead of scattered matches")
    func fzfScoringAndFolders() {
        let files = [
            "apps/apple/macOS/MacWorkbenchView.swift",
            "apps/apple/Shared/SessionThreadView.swift",
            "src/renderer/src/features/session/composer/mentions.ts",
            "docs/my-weird-notes.md",
        ]
        let rows = ComposerPathMatcher.matchMentions(query: "mwv", files: files)
        #expect(rows.first?.path == "apps/apple/macOS/MacWorkbenchView.swift")
        #expect(rows.first?.isFolder == false)
        #expect(rows.first?.positions.count == 3)

        let folders = ComposerPathMatcher.folders(of: files)
        #expect(folders.contains("apps/apple/macOS/"))
        #expect(folders.contains("apps/apple/"))
        #expect(folders.contains("apps/"))

        let folderMatch = ComposerPathMatcher.matchMentions(query: "macOS/", files: files)
        #expect(folderMatch.contains(where: { $0.isFolder && $0.path == "apps/apple/macOS" }))
    }

    @Test("usedFiles returns most recently read/edited known project files without duplicates")
    func usedFilesOrder() {
        let entries: [ThreadEntry] = [
            .tool(ToolEntryData(
                id: "t1",
                title: "Read",
                toolKind: "read",
                status: "completed",
                locations: [ToolLocation(path: "/repo/src/a.swift")]
            )),
            .tool(ToolEntryData(
                id: "t2",
                title: "Edit",
                toolKind: "edit",
                status: "completed",
                content: [.diff(path: "/repo/src/b.swift", oldText: "", newText: "")]
            )),
            .tool(ToolEntryData(
                id: "t3",
                title: "Read again",
                toolKind: "read",
                status: "completed",
                locations: [ToolLocation(path: "/repo/src/a.swift"), ToolLocation(path: "/other/x.swift")]
            )),
        ]
        let used = ComposerPathMatcher.usedFiles(
            from: entries,
            projectPath: "/repo",
            known: ["src/a.swift", "src/b.swift", "src/c.swift"]
        )
        #expect(used == ["src/a.swift", "src/b.swift"])
    }

    @Test("mention trigger supports mid-sentence, Chinese without space, and full-width at-sign")
    func mentionTriggerChineseAndMidSentence() {
        let s1 = "请看看＠MacView然后再改"
        let caret1 = ("请看看＠MacView" as NSString).length
        let m1 = ComposerTrigger.mentionAt(text: s1, caretUTF16: caret1)
        #expect(m1?.query == "MacView")
        #expect(m1?.startUTF16 == ("请看看" as NSString).length)

        let edit = ComposerTrigger.replaceMention(text: s1, mention: m1!, name: "MacWorkbenchView.swift")
        #expect(edit.text == "请看看@MacWorkbenchView.swift 然后再改")

        // Email-like ASCII text must not trigger.
        let email = "mail foo@bar"
        #expect(ComposerTrigger.mentionAt(text: email, caretUTF16: (email as NSString).length) == nil)
    }

    @Test("placeCommand moves mid-sentence slash command to front and keeps caret")
    func placeCommandMidSentence() {
        let text = "/old fix /com please"
        let caret = ("/old fix /com" as NSString).length
        let slash = ComposerTrigger.slashAt(text: text, caretUTF16: caret)
        #expect(slash?.query == "com")
        let edit = ComposerTrigger.placeCommand(
            text: text,
            slash: slash!,
            name: "compact",
            knownNames: ["old", "compact"]
        )
        #expect(edit.text == "/compact fix please")
        #expect(edit.caretUTF16 == ("/compact fix " as NSString).length)
    }

    @Test("findChips parses commands, file mentions with line ranges, and GitHub links")
    func chipsParsing() {
        let text = "/review check @App.swift:41-44 and https://github.com/example/app/pull/2271."
        let chips = ComposerChipsParser.findChips(
            in: text,
            commands: ["review"],
            resolveMention: { name in
                name == "App.swift"
                    ? ComposerResolvedMention(kind: .file, path: "Sources/App.swift", attachmentKey: "att-1")
                    : nil
            }
        )
        #expect(chips.count == 3)
        if case .command(_, _, let name) = chips[0] {
            #expect(name == "review")
        } else {
            Issue.record("Expected command chip")
        }
        if case .mention(_, _, let kind, _, let label, let lines, _, let key, _) = chips[1] {
            #expect(kind == .file)
            #expect(label == "App.swift")
            #expect(lines == "41–44")
            #expect(key == "att-1")
        } else {
            Issue.record("Expected mention chip")
        }
        if case .link(_, _, let url, _, _, let isLocal, let gh) = chips[2] {
            #expect(url == "https://github.com/example/app/pull/2271")
            #expect(isLocal == false)
            #expect(gh == ComposerGitHubRef(owner: "example", repo: "app", kind: .pull, number: 2271))
        } else {
            Issue.record("Expected link chip")
        }
    }

    @Test("commentsMessage and textThumb roundtrip")
    func commentsAndThumb() {
        let formatted = ComposerComments.commentsMessage(
            comments: [DraftReplyComment(passage: "> quoted\nline 2", comment: "fix this")],
            text: "thanks"
        )
        #expect(formatted == "> \\> quoted\n> line 2\n\nfix this\n\nthanks")

        let sample = "line1\nline2\nline3\nline4"
        let thumb = ComposerAttachmentRules.textThumb(sample)
        let parsed = ComposerAttachmentRules.readTextThumb(thumb)
        #expect(parsed?.count == 4)
        #expect(parsed?.lines == ["line1", "line2", "line3"])
    }

    @Test("session matcher ranks title matches ahead of agent/branch matches and disambiguates duplicate titles")
    func sessionMatcherAndTokens() {
        let s1 = ComposerSessionCandidate(
            id: "aaaa1111",
            title: "支付模块重构",
            agentId: "claude-code",
            agentName: "Claude Code",
            projectPath: "/repo",
            branch: "feat/pay",
            updatedAt: 200
        )
        let s2 = ComposerSessionCandidate(
            id: "bbbb2222",
            title: "修复构建脚本",
            agentId: "codex",
            agentName: "Codex CLI",
            projectPath: "/repo",
            branch: "fix/build",
            updatedAt: 300
        )

        let bare = ComposerSessionMatcher.matchSessions(query: "", candidates: [s1, s2])
        #expect(bare.map(\.id) == ["bbbb2222", "aaaa1111"])

        let byTitle = ComposerSessionMatcher.matchSessions(query: "支付重构", candidates: [s1, s2])
        #expect(byTitle.first?.id == "aaaa1111")
        #expect(byTitle.first?.titlePositions == [0, 1, 4, 5])

        let byAgent = ComposerSessionMatcher.matchSessions(query: "codex", candidates: [s1, s2])
        #expect(byAgent.first?.id == "bbbb2222")

        let tok1 = ComposerSessionMatcher.makeToken(title: "支付 [重构]", sessionId: "aaaa1111", existingTokens: [])
        #expect(tok1 == "@[支付 (重构)]")
        let tok2 = ComposerSessionMatcher.makeToken(title: "支付 [重构]", sessionId: "bbbb2222", existingTokens: [tok1])
        #expect(tok2 == "@[支付 (重构) #bbbb]")
    }

    @Test("findChips recognizes session reference tokens with spaces and Chinese characters")
    func sessionChipsAndContextFormatter() {
        let ref = DraftSessionReference(
            id: "sess-42",
            token: "@[支付模块 重构]",
            title: "支付模块 重构",
            agentId: "claude-code",
            agentName: "Claude Code",
            projectPath: "/repo",
            updatedAt: 500
        )
        let text = "参考 @[支付模块 重构] 的方案，再看一下 https://example.com/docs"
        let chips = ComposerChipsParser.findChips(
            in: text,
            commands: [],
            sessionReferences: [ref],
            resolveMention: { _ in nil }
        )
        #expect(chips.count == 2)
        if case .session(_, _, let raw, let sid, let title, let agent, let missing) = chips[0] {
            #expect(raw == "@[支付模块 重构]")
            #expect(sid == "sess-42")
            #expect(title == "支付模块 重构")
            #expect(agent == "Claude Code")
            #expect(missing == false)
        } else {
            Issue.record("Expected session chip")
        }

        let entries: [ThreadEntry] = [
            .user(id: "u1", text: "请分析支付模块的幂等性", content: [], at: 10, approval: false),
            .thought(id: "th1", markdown: "internal reasoning that should be omitted", streaming: false, durationMs: 5),
            .tool(ToolEntryData(
                id: "t1",
                title: "Edit PaymentService.swift",
                toolKind: "edit",
                status: "completed",
                content: [.diff(path: "Sources/PaymentService.swift", oldText: "", newText: "")]
            )),
            .agent(id: "a1", markdown: "已加上基于 orderId 的幂等键校验。", streaming: false, at: 20),
            .user(id: "u2", text: "补充下超时重试逻辑", content: [], at: 30, approval: false),
            .agent(id: "a2", markdown: "已增加指数退避重试。", streaming: false, at: 40),
        ]

        let preview = ComposerSessionContextFormatter.preview(from: entries)
        #expect(preview.turnCount == 2)
        #expect(preview.excerpts.count == 3)

        let block = ComposerSessionContextFormatter.formatContextBlock(reference: ref, entries: entries)
        #expect(block.contains("<referenced_session id=\"sess-42\""))
        #expect(block.contains("请分析支付模块的幂等性"))
        #expect(block.contains("edited Sources/PaymentService.swift"))
        #expect(!block.contains("internal reasoning that should be omitted"))

        let prompt = ComposerSessionContextFormatter.composePromptWithSessionContexts(
            text: "按 @[支付模块 重构] 同步修改退款接口",
            contexts: [block]
        )
        #expect(prompt.hasPrefix("按 @[支付模块 重构] 同步修改退款接口\n\n<referenced_sessions>"))
    }

    @Test("waiting card resolves Enter/Esc actions across permission and protocol cards")
    func waitingCardResolution() {
        let perm = PendingPermission(
            requestId: "req-1",
            options: [
                PermissionOption(id: "opt-allow", name: "Allow", kind: "allow_once", preferred: true),
                PermissionOption(id: "opt-deny", name: "Deny", kind: "reject_once"),
            ]
        )
        let entries: [ThreadEntry] = [
            .tool(ToolEntryData(id: "t1", title: "Bash", toolKind: "execute", status: "running", permission: perm)),
        ]
        #expect(ComposerWaitingCard.action(for: .enter, in: entries) == .respondPermission(requestId: "req-1", optionId: "opt-allow"))
        #expect(ComposerWaitingCard.action(for: .escape, in: entries) == .respondPermission(requestId: "req-1", optionId: "opt-deny"))
    }

    @Test("Chips parser resolves unspaced CJK text after @file mentions and compares visual content ignoring UTF-16 offsets")
    func cjkTrailingMentionsAndVisualEquality() {
        let known: [String: ComposerResolvedMention] = [
            "README.md": ComposerResolvedMention(kind: .file, path: "README.md", attachmentKey: "k1"),
            "App.swift": ComposerResolvedMention(kind: .file, path: "macOS/App.swift", attachmentKey: "k2"),
            "foo.ts": ComposerResolvedMention(kind: .file, path: "src/foo.ts", attachmentKey: "k3"),
            "bar.ts": ComposerResolvedMention(kind: .file, path: "src/bar.ts", attachmentKey: "k4"),
        ]
        // Unspaced CJK after @file, CJK between two @files, and adjacent @bar.ts not poisoning @foo.ts.
        let chips = ComposerChipsParser.findChips(
            in: "先看@README.md看看 再改@App.swift:12-20分析一下 @foo.ts和@bar.ts",
            commands: [],
            resolveMention: { known[$0] }
        )
        #expect(chips.count == 4)
        #expect(chips[0].rawText == "@README.md")
        #expect(chips[1].rawText == "@App.swift:12-20")
        #expect(chips[2].rawText == "@foo.ts")
        #expect(chips[3].rawText == "@bar.ts")

        // Adjacent `@foo.ts@bar.ts` still resolves `@foo.ts` rather than swallowing `@bar.ts` into one dead token,
        // while `alice@bar.ts` stays plain email text.
        let adjacent = ComposerChipsParser.findChips(
            in: "@foo.ts@bar.ts alice@bar.ts",
            commands: [],
            resolveMention: { known[$0] }
        )
        #expect(adjacent.count == 1)
        #expect(adjacent[0].rawText == "@foo.ts")

        let shifted = ComposerChipsParser.findChips(
            in: "前缀 先看@README.md看看",
            commands: [],
            resolveMention: { known[$0] }
        )
        #expect(shifted.count == 1)
        #expect(shifted[0].fromUTF16 != chips[0].fromUTF16)
        #expect(shifted[0].hasSameVisualContent(as: chips[0]))
        #expect(!shifted[0].hasSameVisualContent(as: chips[1]))
    }
}
