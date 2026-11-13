import Testing
@testable import CommaSwitcher

struct PunctuationStyleTests {
    @Test func rawValuesFollowSystemSettingsOrder() {
        #expect(PunctuationStyle.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(PunctuationStyle.allCases.map(\.label) == ["。、", "。，", "．、", "．，"])
    }

    @Test func periodAndComma() {
        #expect(PunctuationStyle.maruComma.period == "。")
        #expect(PunctuationStyle.maruComma.comma == "，")
        #expect(PunctuationStyle.periodTen.period == "．")
        #expect(PunctuationStyle.periodTen.comma == "、")
    }

    @Test func unknownValueIsNil() {
        #expect(PunctuationStyle(rawValue: 4) == nil)
        #expect(PunctuationStyle(rawValue: -1) == nil)
    }
}
