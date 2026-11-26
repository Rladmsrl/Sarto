import SwiftUI
import Testing
@testable import PrismDesign

private func option(_ id: String, tier: PrismModelTier? = nil, group: String? = nil, older: Bool = false, pinned: Bool = false) -> PrismModelOption {
    PrismModelOption(
        id: id,
        name: id.uppercased(),
        subtitle: "",
        brandColor: .gray,
        tag: "",
        isOlder: older,
        tier: tier,
        group: group,
        isPinned: pinned
    )
}

@Suite("Model menu layout shared by the popovers and the number keys")
struct ModelMenuLayoutTests {
    @Test("Tiers split the main list from More models, and only the main list takes number keys")
    func tiersDecideTheMainList() {
        let models = [
            option("pinned", tier: .main, pinned: true),
            option("a", tier: .main),
            option("b", tier: .main),
            option("c", tier: .main),
            option("d", tier: .more, group: "x"),
            option("e", tier: .more, group: "y"),
        ]
        let split = PrismModelMenuLayout.split(models)
        #expect(split.main.map(\.id) == ["pinned", "a", "b", "c"])
        #expect(split.more.map(\.id) == ["d", "e"])
        #expect(PrismModelMenuLayout.numbered(models).map(\.id) == ["pinned", "a", "b", "c"])
    }

    @Test("Without tiers the older rule holds: non-older first, else the first four")
    func olderRuleWithoutTiers() {
        let flagged = [option("new"), option("old", older: true), option("newer")]
        #expect(PrismModelMenuLayout.split(flagged).main.map(\.id) == ["new", "newer"])
        let plain = (1...6).map { option("m\($0)") }
        #expect(PrismModelMenuLayout.numbered(plain).map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(PrismModelMenuLayout.split(plain).more.map(\.id) == ["m5", "m6"])
    }

    @Test("Closed, a chosen model of More models follows the main list; open, More models lists by provider")
    func sectionsFollowTheMenusRule() {
        let models = [
            option("a", tier: .main),
            option("b", tier: .more, group: "openai"),
            option("c", tier: .more, group: "deepseek"),
            option("d", tier: .more, group: "openai"),
        ]
        let closed = PrismModelMenuLayout.sections(models, selectedID: "c", query: "", expanded: false)
        #expect(closed.map(\.kind) == [.main])
        #expect(closed[0].models.map(\.id) == ["a", "c"])

        let open = PrismModelMenuLayout.sections(models, selectedID: "c", query: "", expanded: true)
        #expect(open.map(\.heading) == [nil, "openai", "deepseek"])
        #expect(open[1].models.map(\.id) == ["b", "d"])

        let found = PrismModelMenuLayout.sections(models, selectedID: nil, query: " OPEN b ", expanded: false)
        #expect(found.map(\.kind) == [.results])
        #expect(found.flatMap(\.models).map(\.id) == ["b"])
    }
}
