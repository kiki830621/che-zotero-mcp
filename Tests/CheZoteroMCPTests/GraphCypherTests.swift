import XCTest
@testable import CheZoteroMCPCore

final class GraphCypherTests: XCTestCase {

    private func buildTestGraph() -> GraphEngine {
        let engine = GraphEngine()
        let a = engine.addNode(label: .researcher, properties: ["name": "Yi-Hau Chen"])
        let b = engine.addNode(label: .researcher, properties: ["name": "Che Cheng"])
        let p = engine.addNode(label: .paper, properties: ["title": "Joint Paper", "doi": "10.1/joint"])
        let inst = engine.addNode(label: .institution, properties: ["name": "Academia Sinica"])

        _ = engine.addEdge(type: .coAuthor, source: a, target: b, properties: ["weight": "5"])
        _ = engine.addEdge(type: .authored, source: a, target: p, properties: [:])
        _ = engine.addEdge(type: .authored, source: b, target: p, properties: [:])
        _ = engine.addEdge(type: .affiliatedWith, source: a, target: inst, properties: [:])
        return engine
    }

    func testSimpleMatch() throws {
        let engine = buildTestGraph()
        let result = try GraphCypher.execute(
            "MATCH (r:Researcher)-[:CO_AUTHOR]->(c:Researcher) WHERE r.name = \"Yi-Hau Chen\" RETURN c",
            on: engine
        )
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0]["c.name"], "Che Cheng")
    }

    func testMatchWithContains() throws {
        let engine = buildTestGraph()
        let result = try GraphCypher.execute(
            "MATCH (r:Researcher)-[:AFFILIATED_WITH]->(i:Institution) WHERE i.name CONTAINS \"Academia\" RETURN r",
            on: engine
        )
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0]["r.name"], "Yi-Hau Chen")
    }

    func testMatchNoResults() throws {
        let engine = buildTestGraph()
        let result = try GraphCypher.execute(
            "MATCH (r:Researcher) WHERE r.name = \"Nobody\" RETURN r",
            on: engine
        )
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testInvalidQueryThrows() {
        let engine = buildTestGraph()
        XCTAssertThrowsError(try GraphCypher.execute("INVALID QUERY", on: engine))
    }
}
