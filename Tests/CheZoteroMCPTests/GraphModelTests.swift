import XCTest
@testable import CheZoteroMCPCore

final class GraphModelTests: XCTestCase {

    func testNodeLabelRawValues() {
        XCTAssertEqual(NodeLabel.researcher.rawValue, 0)
        XCTAssertEqual(NodeLabel.paper.rawValue, 1)
        XCTAssertEqual(NodeLabel.institution.rawValue, 2)
        XCTAssertEqual(NodeLabel.journal.rawValue, 3)
        XCTAssertEqual(NodeLabel(rawValue: 0), .researcher)
        XCTAssertNil(NodeLabel(rawValue: 99))
    }

    func testEdgeTypeRawValues() {
        XCTAssertEqual(EdgeType.authored.rawValue, 0)
        XCTAssertEqual(EdgeType.coAuthor.rawValue, 1)
        XCTAssertEqual(EdgeType.publishedIn.rawValue, 2)
        XCTAssertEqual(EdgeType.affiliatedWith.rawValue, 3)
        XCTAssertEqual(EdgeType.cites.rawValue, 4)
        XCTAssertEqual(EdgeType.advisorOf.rawValue, 5)
        XCTAssertNil(EdgeType(rawValue: 99))
    }

    func testNodeLabelDisplayName() {
        XCTAssertEqual(NodeLabel.researcher.displayName, "Researcher")
        XCTAssertEqual(NodeLabel.paper.displayName, "Paper")
        XCTAssertEqual(NodeLabel.institution.displayName, "Institution")
        XCTAssertEqual(NodeLabel.journal.displayName, "Journal")
    }

    func testEdgeTypeDisplayName() {
        XCTAssertEqual(EdgeType.authored.displayName, "AUTHORED")
        XCTAssertEqual(EdgeType.coAuthor.displayName, "CO_AUTHOR")
        XCTAssertEqual(EdgeType.publishedIn.displayName, "PUBLISHED_IN")
        XCTAssertEqual(EdgeType.affiliatedWith.displayName, "AFFILIATED_WITH")
        XCTAssertEqual(EdgeType.cites.displayName, "CITES")
        XCTAssertEqual(EdgeType.advisorOf.displayName, "ADVISOR_OF")
    }
}
