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

    // MARK: - GraphNode and GraphEdge

    func testGraphNodeCreation() {
        let node = GraphNode(id: 1, label: .researcher, properties: ["name": "Che Cheng"])
        XCTAssertEqual(node.id, 1)
        XCTAssertEqual(node.label, .researcher)
        XCTAssertEqual(node.properties["name"], "Che Cheng")
        XCTAssertTrue(node.edges.isEmpty)
    }

    func testGraphEdgeCreation() {
        let src = GraphNode(id: 1, label: .researcher, properties: ["name": "A"])
        let tgt = GraphNode(id: 2, label: .paper, properties: ["title": "P1"])
        let edge = GraphEdge(id: 100, type: .authored, source: src, target: tgt, properties: [:])

        XCTAssertEqual(edge.id, 100)
        XCTAssertEqual(edge.type, .authored)
        XCTAssertTrue(edge.source === src)
        XCTAssertTrue(edge.target === tgt)
    }

    func testGraphNodeNeighbors() {
        let a = GraphNode(id: 1, label: .researcher, properties: ["name": "A"])
        let b = GraphNode(id: 2, label: .paper, properties: ["title": "P1"])
        let edge = GraphEdge(id: 100, type: .authored, source: a, target: b, properties: [:])
        a.edges.append(edge)
        b.edges.append(edge)

        let outgoing = a.neighbors(direction: .outgoing)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertTrue(outgoing[0] === b)

        let incoming = b.neighbors(direction: .incoming)
        XCTAssertEqual(incoming.count, 1)
        XCTAssertTrue(incoming[0] === a)

        let both = a.neighbors(direction: .both)
        XCTAssertEqual(both.count, 1)
    }

    func testGraphNodeNeighborsFilteredByEdgeType() {
        let a = GraphNode(id: 1, label: .researcher, properties: [:])
        let b = GraphNode(id: 2, label: .paper, properties: [:])
        let c = GraphNode(id: 3, label: .researcher, properties: [:])
        let e1 = GraphEdge(id: 10, type: .authored, source: a, target: b, properties: [:])
        let e2 = GraphEdge(id: 11, type: .coAuthor, source: a, target: c, properties: [:])
        a.edges.append(contentsOf: [e1, e2])
        b.edges.append(e1)
        c.edges.append(e2)

        let coauthors = a.neighbors(direction: .outgoing, edgeType: .coAuthor)
        XCTAssertEqual(coauthors.count, 1)
        XCTAssertTrue(coauthors[0] === c)
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
