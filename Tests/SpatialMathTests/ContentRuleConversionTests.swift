import Foundation
import XCTest
@testable import SpatialMath

final class ContentRuleConversionTests: XCTestCase {
    func testNetworkExceptionScopeAndCSS() throws {
        let input = """
            [Adblock Plus 2.0]
            ! example only
            ||ads.example.com^
            ||ads.example.com/a.js$script,third-party,domain=example.org
            @@||ads.example.com/a.js$script,domain=example.org
            example.org##.ad > .banner
            ||blocked.example.com^$document
            """
        let result = try ContentRuleConversion.convert(Data(input.utf8))
        XCTAssertEqual(
            result.entries.map(\.action.type), ["block", "block", "block", "ignore-previous-rules", "css-display-none"])
        XCTAssertEqual(result.exceptions, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.entries[1].trigger.include, ["*example.org"])
        XCTAssertEqual(result.entries[1].trigger.types, ["script"])
        XCTAssertEqual(result.entries[1].trigger.load, ["third-party"])
        XCTAssertEqual(result.entries[2].trigger.types, ["document"])
        XCTAssertEqual(result.entries.last?.action.selector, ".ad > .banner")
        XCTAssertEqual(result.entries.last?.trigger.include, ["*example.org"])
    }

    func testUnsupportedRulesAreCountedRatherThanBroadened() throws {
        let input = """
            example.com##+js(abort-on-property-read, foo)
            example.com#?#.ad:has-text(test)
            example.com#@#.ad
            /example\\.com.*ads/
            ||ads.example.com^$redirect=noopjs
            ||ads.example.com^$domain=example.org|~sub.example.org
            ||ads.example.com^$removeparam=foo
            ##div>>p
            ||ads.example.com^
            """
        let result = try ContentRuleConversion.convert(Data(input.utf8))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.skipped, 8)
        XCTAssertEqual(result.examples.map(\.line), Array(1...8))
        XCTAssertEqual(ContentRuleConversion.editorExamples(input).count, 8)
    }

    func testWebKitJSONRestrictsActionsAndRejectsInvalidInput() throws {
        let input = """
            [{"trigger":{"url-filter":"example"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"example"},"action":{"type":"redirect"}},
             {"trigger":{"url-filter":"example","if-domain":["example.com"]},"action":{"type":"ignore-previous-rules"}}]
            """
        let result = try ContentRuleConversion.convert(Data(input.utf8))
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.exceptions, 1)
        XCTAssertThrowsError(try ContentRuleConversion.convert(Data("[incomplete".utf8)))
        XCTAssertThrowsError(
            try ContentRuleConversion.convert(Data(repeating: 0, count: ContentRuleConversion.byteLimit + 1)))
    }

    func testRuleLimitRejectsJSONWithoutTruncating() {
        let rule = #"{"trigger":{"url-filter":"example"},"action":{"type":"block"}}"#
        let data = Data(("[" + String(repeating: rule + ",", count: ContentRuleConversion.ruleLimit) + rule + "]").utf8)
        XCTAssertThrowsError(try ContentRuleConversion.convert(data)) {
            guard case ContentRuleConversion.Failure.tooMany = $0 else {
                return XCTFail("Expected the rule limit")
            }
        }
    }
}
