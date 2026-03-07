import XCTest
@testable import CheZoteroMCPCore

final class GraphEngineTests: XCTestCase {

    func testAddNode() {
        let engine = GraphEngine()
        let node = engine.addNode(label: .researcher, properties: ["name": "Che Cheng"])
        XCTAssertEqual(node.label, .researcher)
        XCTAssertEqual(node.properties["name"], "Che Cheng")
        XCTAssertEqual(engine.nodeCount, 1)
    }

    func testAddMultipleNodes() {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: ["name": "A"])
        let b = engine.addNode(label: .paper, properties: ["title": "P1"])
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(engine.nodeCount, 2)
    }

    func testAddEdge() {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: ["name": "A"])
        let b = engine.addNode(label: .paper, properties: ["title": "P1"])
        let edge = engine.addEdge(type: .authored, source: a, target: b, properties: [:])

        XCTAssertEqual(edge.type, .authored)
        XCTAssertEqual(engine.edgeCount, 1)
        XCTAssertEqual(a.edges.count, 1)
        XCTAssertEqual(b.edges.count, 1)
    }

    func testRemoveNode() {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: ["name": "A"])
        let b = engine.addNode(label: .paper, properties: ["title": "P1"])
        _ = engine.addEdge(type: .authored, source: a, target: b, properties: [:])

        engine.removeNode(id: a.id)
        XCTAssertEqual(engine.nodeCount, 1)
        XCTAssertEqual(engine.edgeCount, 0)
        XCTAssertTrue(b.edges.isEmpty)
    }

    func testRemoveEdge() {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: [:])
        let b = engine.addNode(label: .paper, properties: [:])
        let edge = engine.addEdge(type: .authored, source: a, target: b, properties: [:])

        engine.removeEdge(id: edge.id)
        XCTAssertEqual(engine.edgeCount, 0)
        XCTAssertTrue(a.edges.isEmpty)
        XCTAssertTrue(b.edges.isEmpty)
    }

    func testGetNodeById() {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: ["name": "A"])
        XCTAssertTrue(engine.getNode(id: a.id) === a)
        XCTAssertNil(engine.getNode(id: 9999))
    }

    func testNameIndex() {
        let engine = GraphEngine()
        _ = engine.addNode(label: .researcher, properties: ["name": "Yi-Hau Chen"])
        _ = engine.addNode(label: .researcher, properties: ["name": "Che Cheng"])

        let results = engine.findByName("Yi-Hau Chen")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].properties["name"], "Yi-Hau Chen")
    }

    func testLabelIndex() {
        let engine = GraphEngine()
        _ = engine.addNode(label: .researcher, properties: ["name": "A"])
        _ = engine.addNode(label: .paper, properties: ["title": "P1"])
        _ = engine.addNode(label: .researcher, properties: ["name": "B"])

        let researchers = engine.findByLabel(.researcher)
        XCTAssertEqual(researchers.count, 2)

        let papers = engine.findByLabel(.paper)
        XCTAssertEqual(papers.count, 1)
    }

    func testDOIIndex() {
        let engine = GraphEngine()
        _ = engine.addNode(label: .paper, properties: ["title": "P1", "doi": "10.1234/test"])

        let found = engine.findByDOI("10.1234/test")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.properties["title"], "P1")
        XCTAssertNil(engine.findByDOI("10.9999/nonexistent"))
    }

    func testDirtyFlag() {
        let engine = GraphEngine()
        XCTAssertFalse(engine.isDirty)
        _ = engine.addNode(label: .researcher, properties: [:])
        XCTAssertTrue(engine.isDirty)
    }

    func testStats() {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: ["name": "A"])
        let b = engine.addNode(label: .paper, properties: ["title": "P1"])
        _ = engine.addEdge(type: .authored, source: a, target: b, properties: [:])

        let stats = engine.stats()
        XCTAssertEqual(stats.totalNodes, 2)
        XCTAssertEqual(stats.totalEdges, 1)
        XCTAssertEqual(stats.nodesByLabel[.researcher], 1)
        XCTAssertEqual(stats.nodesByLabel[.paper], 1)
        XCTAssertEqual(stats.edgesByType[.authored], 1)
    }
}
