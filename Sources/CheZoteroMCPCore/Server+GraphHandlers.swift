import Foundation
import MCP

extension CheZoteroMCPServer {

    // MARK: - Stats

    func handleGraphStats(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let stats = graphEngine.stats()
        var lines = [
            "Graph Statistics:",
            "  Nodes: \(stats.totalNodes)",
            "  Edges: \(stats.totalEdges)",
            "",
            "Nodes by type:"
        ]
        for label in NodeLabel.allCases {
            let count = stats.nodesByLabel[label] ?? 0
            lines.append("  \(label.displayName): \(count)")
        }
        lines.append("")
        lines.append("Edges by type:")
        for type in EdgeType.allCases {
            let count = stats.edgesByType[type] ?? 0
            lines.append("  \(type.displayName): \(count)")
        }
        if !stats.topNodesByDegree.isEmpty {
            lines.append("")
            lines.append("Top nodes by degree:")
            for (node, degree) in stats.topNodesByDegree {
                let name = node.properties["name"] ?? node.properties["title"] ?? "id:\(node.id)"
                lines.append("  \(name) [\(node.label.displayName)]: \(degree) edges")
            }
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Mutation

    func handleGraphAddNode(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let labelStr = params.arguments?["label"]?.stringValue ?? ""
        guard let label = parseNodeLabel(labelStr) else {
            return CallTool.Result(content: [.text("Invalid label: \(labelStr). Use: Researcher, Paper, Institution, Journal")], isError: true)
        }
        var properties: [String: String] = [:]
        if let propsVal = params.arguments?["properties"], case .object(let obj) = propsVal {
            for (k, v) in obj { properties[k] = v.stringValue }
        }
        let node = graphEngine.addNode(label: label, properties: properties)
        return CallTool.Result(content: [.text("Created \(label.displayName) node (id: \(node.id))")], isError: false)
    }

    func handleGraphAddEdge(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let typeStr = params.arguments?["type"]?.stringValue ?? ""
        guard let edgeType = parseEdgeType(typeStr) else {
            return CallTool.Result(content: [.text("Invalid edge type: \(typeStr)")], isError: true)
        }
        let sourceId = UInt32(intFromValue(params.arguments?["source_id"]) ?? 0)
        let targetId = UInt32(intFromValue(params.arguments?["target_id"]) ?? 0)
        guard let source = graphEngine.getNode(id: sourceId) else {
            return CallTool.Result(content: [.text("Source node \(sourceId) not found")], isError: true)
        }
        guard let target = graphEngine.getNode(id: targetId) else {
            return CallTool.Result(content: [.text("Target node \(targetId) not found")], isError: true)
        }
        var properties: [String: String] = [:]
        if let propsVal = params.arguments?["properties"], case .object(let obj) = propsVal {
            for (k, v) in obj { properties[k] = v.stringValue }
        }
        let edge = graphEngine.addEdge(type: edgeType, source: source, target: target, properties: properties)
        let srcName = source.properties["name"] ?? source.properties["title"] ?? "id:\(source.id)"
        let tgtName = target.properties["name"] ?? target.properties["title"] ?? "id:\(target.id)"
        return CallTool.Result(content: [.text("Created \(edgeType.displayName) edge (id: \(edge.id)): \(srcName) → \(tgtName)")], isError: false)
    }

    func handleGraphRemoveNode(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let id = UInt32(intFromValue(params.arguments?["node_id"]) ?? 0)
        guard graphEngine.getNode(id: id) != nil else {
            return CallTool.Result(content: [.text("Node \(id) not found")], isError: true)
        }
        graphEngine.removeNode(id: id)
        return CallTool.Result(content: [.text("Removed node \(id) and all its edges")], isError: false)
    }

    func handleGraphRemoveEdge(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let id = UInt32(intFromValue(params.arguments?["edge_id"]) ?? 0)
        guard graphEngine.getEdge(id: id) != nil else {
            return CallTool.Result(content: [.text("Edge \(id) not found")], isError: true)
        }
        graphEngine.removeEdge(id: id)
        return CallTool.Result(content: [.text("Removed edge \(id)")], isError: false)
    }

    func handleGraphSave(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.che-zotero-mcp/graph.bin"
        try GraphPersistence.save(engine: graphEngine, to: path)
        return CallTool.Result(content: [.text("Graph saved to \(path) (\(graphEngine.nodeCount) nodes, \(graphEngine.edgeCount) edges)")], isError: false)
    }

    // MARK: - Queries

    func handleGraphNeighbors(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let nodeId = UInt32(intFromValue(params.arguments?["node_id"]) ?? 0)
        guard let node = graphEngine.getNode(id: nodeId) else {
            return CallTool.Result(content: [.text("Node \(nodeId) not found")], isError: true)
        }
        let edgeType = params.arguments?["edge_type"]?.stringValue.flatMap { parseEdgeType($0) }
        let dirStr = params.arguments?["direction"]?.stringValue ?? "both"
        let direction: EdgeDirection = dirStr == "outgoing" ? .outgoing : dirStr == "incoming" ? .incoming : .both

        let neighbors = GraphAlgorithms.neighbors(of: node, edgeType: edgeType, direction: direction)
        if neighbors.isEmpty {
            return CallTool.Result(content: [.text("No neighbors found")], isError: false)
        }
        let nodeName = node.properties["name"] ?? node.properties["title"] ?? "id:\(node.id)"
        var lines = ["Neighbors of \(nodeName) (\(neighbors.count)):"]
        for n in neighbors {
            let name = n.properties["name"] ?? n.properties["title"] ?? "id:\(n.id)"
            lines.append("  [\(n.label.displayName)] \(name) (id: \(n.id))")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleGraphShortestPath(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let fromId = UInt32(intFromValue(params.arguments?["from_id"]) ?? 0)
        let toId = UInt32(intFromValue(params.arguments?["to_id"]) ?? 0)
        guard let from = graphEngine.getNode(id: fromId) else {
            return CallTool.Result(content: [.text("From node \(fromId) not found")], isError: true)
        }
        guard let to = graphEngine.getNode(id: toId) else {
            return CallTool.Result(content: [.text("To node \(toId) not found")], isError: true)
        }
        let edgeTypes: Set<EdgeType>? = params.arguments?["edge_types"]?.stringValue
            .flatMap { str -> Set<EdgeType>? in
                let types = str.split(separator: ",").compactMap { parseEdgeType(String($0).trimmingCharacters(in: .whitespaces)) }
                return types.isEmpty ? nil : Set(types)
            }

        guard let path = GraphAlgorithms.shortestPath(from: from, to: to, edgeTypes: edgeTypes) else {
            return CallTool.Result(content: [.text("No path found")], isError: false)
        }

        let names = path.map { $0.properties["name"] ?? $0.properties["title"] ?? "id:\($0.id)" }
        return CallTool.Result(content: [.text("Path (\(path.count - 1) hops): \(names.joined(separator: " → "))")], isError: false)
    }

    func handleGraphCoAuthorStats(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let nodeId = UInt32(intFromValue(params.arguments?["node_id"]) ?? 0)
        let node: GraphNode
        if let found = graphEngine.getNode(id: nodeId) {
            node = found
        } else {
            let name = params.arguments?["name"]?.stringValue ?? ""
            guard let found = graphEngine.findByName(name).first else {
                return CallTool.Result(content: [.text("Researcher not found")], isError: true)
            }
            node = found
        }

        let stats = GraphAlgorithms.coAuthorStats(for: node, in: graphEngine)
        let name = node.properties["name"] ?? "id:\(node.id)"
        if stats.isEmpty {
            return CallTool.Result(content: [.text("No co-authors found for \(name)")], isError: false)
        }
        var lines = ["Co-author stats for \(name) (\(stats.count) co-authors):"]
        for s in stats {
            let coName = s.coauthor.properties["name"] ?? "id:\(s.coauthor.id)"
            lines.append("  \(coName): \(s.sharedPapers) shared papers")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleGraphCitationNetwork(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let nodeId = UInt32(intFromValue(params.arguments?["node_id"]) ?? 0)
        let depth = intFromValue(params.arguments?["depth"]) ?? 1
        guard let node = graphEngine.getNode(id: nodeId) else {
            return CallTool.Result(content: [.text("Node \(nodeId) not found")], isError: true)
        }
        let tree = GraphAlgorithms.citationNetwork(for: node, depth: depth)
        let title = node.properties["title"] ?? "id:\(node.id)"
        var lines = ["Citation network for: \(title)"]
        lines.append("References (\(tree.references.count)):")
        for ref in tree.references {
            lines.append("  → \(ref.node.properties["title"] ?? "id:\(ref.node.id)")")
        }
        lines.append("Cited by (\(tree.citedBy.count)):")
        for cb in tree.citedBy {
            lines.append("  ← \(cb.node.properties["title"] ?? "id:\(cb.node.id)")")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleGraphCommunity(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let nodeId = UInt32(intFromValue(params.arguments?["node_id"]) ?? 0)
        let maxHops = intFromValue(params.arguments?["max_hops"]) ?? 2
        guard let node = graphEngine.getNode(id: nodeId) else {
            return CallTool.Result(content: [.text("Node \(nodeId) not found")], isError: true)
        }
        let edgeType = params.arguments?["edge_type"]?.stringValue.flatMap { parseEdgeType($0) }
        let community = GraphAlgorithms.community(seed: node, edgeType: edgeType, maxHops: maxHops)
        let name = node.properties["name"] ?? node.properties["title"] ?? "id:\(node.id)"
        var lines = ["Community around \(name) (\(community.count) members, max \(maxHops) hops):"]
        for member in community.sorted(by: { $0.id < $1.id }) {
            let mName = member.properties["name"] ?? member.properties["title"] ?? "id:\(member.id)"
            lines.append("  [\(member.label.displayName)] \(mName) (id: \(member.id))")
        }
        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    func handleGraphQuery(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let query = params.arguments?["query"]?.stringValue ?? ""
        let result = try GraphCypher.execute(query, on: graphEngine)
        if result.rows.isEmpty {
            return CallTool.Result(content: [.text("No results")], isError: false)
        }
        return CallTool.Result(content: [.text(result.summary)], isError: false)
    }

    func handleGraphImportFromZotero(_ params: CallTool.Parameters) throws -> CallTool.Result {
        let collectionKey = params.arguments?["collection_key"]?.stringValue
        let libraryID = try resolveLibraryID(from: params)

        let items: [ZoteroItem]
        if let key = collectionKey {
            items = try reader.getItemsInCollection(collectionKey: key)
        } else {
            items = try reader.getAllItems(libraryID: libraryID)
        }

        let result = GraphImporter.importFromZotero(items: items, into: graphEngine)
        return CallTool.Result(content: [.text(result.summary)], isError: false)
    }

    // MARK: - Helpers

    private func parseNodeLabel(_ str: String) -> NodeLabel? {
        switch str.lowercased() {
        case "researcher": return .researcher
        case "paper": return .paper
        case "institution": return .institution
        case "journal": return .journal
        default: return nil
        }
    }

    private func parseEdgeType(_ str: String) -> EdgeType? {
        switch str.uppercased() {
        case "AUTHORED": return .authored
        case "CO_AUTHOR", "COAUTHOR": return .coAuthor
        case "PUBLISHED_IN", "PUBLISHEDIN": return .publishedIn
        case "AFFILIATED_WITH", "AFFILIATEDWITH": return .affiliatedWith
        case "CITES": return .cites
        case "ADVISOR_OF", "ADVISOROF": return .advisorOf
        default: return nil
        }
    }
}
