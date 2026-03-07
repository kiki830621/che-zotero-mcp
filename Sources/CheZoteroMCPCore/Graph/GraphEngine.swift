import Foundation

// MARK: - Graph Statistics

public struct GraphStats {
    public let totalNodes: Int
    public let totalEdges: Int
    public let nodesByLabel: [NodeLabel: Int]
    public let edgesByType: [EdgeType: Int]
    public let topNodesByDegree: [(node: GraphNode, degree: Int)]
}

// MARK: - Graph Engine

public class GraphEngine {
    private var nodes: [UInt32: GraphNode] = [:]
    private var allEdges: [UInt32: GraphEdge] = [:]
    private var nextNodeId: UInt32 = 1
    private var nextEdgeId: UInt32 = 1
    private(set) public var isDirty: Bool = false

    // Indexes
    private var nameIndex: [String: [GraphNode]] = [:]
    private var labelIndex: [NodeLabel: [GraphNode]] = [:]
    private var doiIndex: [String: GraphNode] = [:]

    public init() {}

    // MARK: - Counts

    public var nodeCount: Int { nodes.count }
    public var edgeCount: Int { allEdges.count }

    // MARK: - Lookup

    public func getNode(id: UInt32) -> GraphNode? { nodes[id] }
    public func getEdge(id: UInt32) -> GraphEdge? { allEdges[id] }

    // MARK: - Index Queries

    public func findByName(_ name: String) -> [GraphNode] {
        nameIndex[name] ?? []
    }

    public func findByLabel(_ label: NodeLabel) -> [GraphNode] {
        labelIndex[label] ?? []
    }

    public func findByDOI(_ doi: String) -> GraphNode? {
        doiIndex[doi]
    }

    // MARK: - Mutation

    @discardableResult
    public func addNode(label: NodeLabel, properties: [String: String]) -> GraphNode {
        let node = GraphNode(id: nextNodeId, label: label, properties: properties)
        nextNodeId += 1
        nodes[node.id] = node
        isDirty = true

        indexNode(node)
        return node
    }

    @discardableResult
    public func addEdge(type: EdgeType, source: GraphNode, target: GraphNode, properties: [String: String]) -> GraphEdge {
        let edge = GraphEdge(id: nextEdgeId, type: type, source: source, target: target, properties: properties)
        nextEdgeId += 1
        allEdges[edge.id] = edge
        source.edges.append(edge)
        target.edges.append(edge)
        isDirty = true
        return edge
    }

    public func removeNode(id: UInt32) {
        guard let node = nodes[id] else { return }

        let edgesToRemove = node.edges
        for edge in edgesToRemove {
            removeEdge(id: edge.id)
        }

        deindexNode(node)
        nodes.removeValue(forKey: id)
        isDirty = true
    }

    public func removeEdge(id: UInt32) {
        guard let edge = allEdges[id] else { return }
        edge.source.edges.removeAll { $0.id == id }
        edge.target.edges.removeAll { $0.id == id }
        allEdges.removeValue(forKey: id)
        isDirty = true
    }

    // MARK: - Stats

    public func stats() -> GraphStats {
        var nodesByLabel: [NodeLabel: Int] = [:]
        for node in nodes.values {
            nodesByLabel[node.label, default: 0] += 1
        }

        var edgesByType: [EdgeType: Int] = [:]
        for edge in allEdges.values {
            edgesByType[edge.type, default: 0] += 1
        }

        let topNodes = nodes.values
            .sorted { $0.degree > $1.degree }
            .prefix(10)
            .map { (node: $0, degree: $0.degree) }

        return GraphStats(
            totalNodes: nodes.count,
            totalEdges: allEdges.count,
            nodesByLabel: nodesByLabel,
            edgesByType: edgesByType,
            topNodesByDegree: Array(topNodes)
        )
    }

    // MARK: - Indexing (private)

    private func indexNode(_ node: GraphNode) {
        if let name = node.properties["name"] {
            nameIndex[name, default: []].append(node)
        }
        labelIndex[node.label, default: []].append(node)
        if let doi = node.properties["doi"] {
            doiIndex[doi] = node
        }
    }

    private func deindexNode(_ node: GraphNode) {
        if let name = node.properties["name"] {
            nameIndex[name]?.removeAll { $0.id == node.id }
            if nameIndex[name]?.isEmpty == true { nameIndex.removeValue(forKey: name) }
        }
        labelIndex[node.label]?.removeAll { $0.id == node.id }
        if labelIndex[node.label]?.isEmpty == true { labelIndex.removeValue(forKey: node.label) }
        if let doi = node.properties["doi"] {
            if doiIndex[doi]?.id == node.id { doiIndex.removeValue(forKey: doi) }
        }
    }

    // MARK: - Persistence hooks

    public func markClean() { isDirty = false }

    public func setNextIds(node: UInt32, edge: UInt32) {
        nextNodeId = node
        nextEdgeId = edge
    }

    public var allNodes: [UInt32: GraphNode] { nodes }
    public var allEdgesDict: [UInt32: GraphEdge] { allEdges }
}
