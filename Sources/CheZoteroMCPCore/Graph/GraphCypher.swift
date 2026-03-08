import Foundation

public struct CypherResult {
    public let columns: [String]
    public let rows: [[String: String]]

    public var summary: String {
        if rows.isEmpty { return "No results." }
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            let fields = columns.compactMap { col -> String? in
                guard let val = row[col] else { return nil }
                return "\(col): \(val)"
            }
            lines.append("\(i + 1). \(fields.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum CypherError: LocalizedError {
    case parseFailed(String)
    case unknownLabel(String)
    case unknownEdgeType(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let msg): return "Cypher parse error: \(msg)"
        case .unknownLabel(let l): return "Unknown node label: \(l)"
        case .unknownEdgeType(let t): return "Unknown edge type: \(t)"
        }
    }
}

/// Simplified Cypher executor.
/// Supports: MATCH (a:Label)-[:EDGE_TYPE]->(b:Label) WHERE a.prop = "value" RETURN b
public enum GraphCypher {

    public static func execute(_ query: String, on engine: GraphEngine) throws -> CypherResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let matchRange = trimmed.range(of: "MATCH ", options: .caseInsensitive) else {
            throw CypherError.parseFailed("Missing MATCH clause")
        }

        let afterMatch = String(trimmed[matchRange.upperBound...])

        let whereClause: String?
        let returnClause: String
        let patternStr: String

        if let whereRange = afterMatch.range(of: " WHERE ", options: .caseInsensitive) {
            patternStr = String(afterMatch[..<whereRange.lowerBound])
            let afterWhere = String(afterMatch[whereRange.upperBound...])
            if let returnRange = afterWhere.range(of: " RETURN ", options: .caseInsensitive) {
                whereClause = String(afterWhere[..<returnRange.lowerBound])
                returnClause = String(afterWhere[returnRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                throw CypherError.parseFailed("Missing RETURN clause")
            }
        } else if let returnRange = afterMatch.range(of: " RETURN ", options: .caseInsensitive) {
            patternStr = String(afterMatch[..<returnRange.lowerBound])
            whereClause = nil
            returnClause = String(afterMatch[returnRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            throw CypherError.parseFailed("Missing RETURN clause")
        }

        let pattern = try parsePattern(patternStr.trimmingCharacters(in: .whitespaces))
        let conditions = whereClause.map { parseConditions($0) } ?? []
        let returnVars = returnClause.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        return try executePattern(pattern: pattern, conditions: conditions, returnVars: returnVars, engine: engine)
    }

    // MARK: - Pattern parsing

    private struct PatternNode {
        let variable: String
        let label: NodeLabel?
    }

    private struct PatternEdge {
        let edgeType: EdgeType?
        let direction: EdgeDirection
    }

    private struct Pattern {
        let nodes: [PatternNode]
        let edges: [PatternEdge]
    }

    private static func parsePattern(_ str: String) throws -> Pattern {
        let nodeRegex = try NSRegularExpression(pattern: #"\((\w+)(?::(\w+))?\)"#)
        let edgeRegex = try NSRegularExpression(pattern: #"-\[:(\w+)\]->"#)
        let edgeBackRegex = try NSRegularExpression(pattern: #"<-\[:(\w+)\]-"#)
        let edgeUndirRegex = try NSRegularExpression(pattern: #"-\[:(\w+)\]-(?!>)"#)

        var nodes: [PatternNode] = []
        let nsStr = str as NSString
        let nodeMatches = nodeRegex.matches(in: str, range: NSRange(location: 0, length: nsStr.length))

        for match in nodeMatches {
            let variable = nsStr.substring(with: match.range(at: 1))
            let labelStr = match.range(at: 2).location != NSNotFound ? nsStr.substring(with: match.range(at: 2)) : nil
            let label = try labelStr.map { try resolveLabel($0) }
            nodes.append(PatternNode(variable: variable, label: label))
        }

        var edges: [PatternEdge] = []

        let fwdMatches = edgeRegex.matches(in: str, range: NSRange(location: 0, length: nsStr.length))
        for match in fwdMatches {
            let typeStr = nsStr.substring(with: match.range(at: 1))
            edges.append(PatternEdge(edgeType: try resolveEdgeType(typeStr), direction: .outgoing))
        }

        let bwdMatches = edgeBackRegex.matches(in: str, range: NSRange(location: 0, length: nsStr.length))
        for match in bwdMatches {
            let typeStr = nsStr.substring(with: match.range(at: 1))
            edges.append(PatternEdge(edgeType: try resolveEdgeType(typeStr), direction: .incoming))
        }

        if edges.isEmpty {
            let undirMatches = edgeUndirRegex.matches(in: str, range: NSRange(location: 0, length: nsStr.length))
            for match in undirMatches {
                let typeStr = nsStr.substring(with: match.range(at: 1))
                edges.append(PatternEdge(edgeType: try resolveEdgeType(typeStr), direction: .both))
            }
        }

        return Pattern(nodes: nodes, edges: edges)
    }

    private static func resolveLabel(_ str: String) throws -> NodeLabel {
        switch str.lowercased() {
        case "researcher": return .researcher
        case "paper": return .paper
        case "institution": return .institution
        case "journal": return .journal
        default: throw CypherError.unknownLabel(str)
        }
    }

    private static func resolveEdgeType(_ str: String) throws -> EdgeType {
        switch str.uppercased() {
        case "AUTHORED": return .authored
        case "CO_AUTHOR": return .coAuthor
        case "PUBLISHED_IN": return .publishedIn
        case "AFFILIATED_WITH": return .affiliatedWith
        case "CITES": return .cites
        case "ADVISOR_OF": return .advisorOf
        default: throw CypherError.unknownEdgeType(str)
        }
    }

    // MARK: - Condition parsing

    private enum ConditionOp {
        case equals(String, String, String)     // var, prop, value
        case contains(String, String, String)   // var, prop, substring
    }

    private static func parseConditions(_ str: String) -> [ConditionOp] {
        var conditions: [ConditionOp] = []
        let parts = str.components(separatedBy: " AND ")

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)

            // var.prop CONTAINS "value"
            if let containsMatch = trimmed.range(of: #"(\w+)\.(\w+)\s+CONTAINS\s+"([^"]*)""#, options: .regularExpression) {
                let matched = String(trimmed[containsMatch])
                let regex = try! NSRegularExpression(pattern: #"(\w+)\.(\w+)\s+CONTAINS\s+"([^"]*)""#)
                if let m = regex.firstMatch(in: matched, range: NSRange(matched.startIndex..., in: matched)) {
                    let variable = (matched as NSString).substring(with: m.range(at: 1))
                    let prop = (matched as NSString).substring(with: m.range(at: 2))
                    let value = (matched as NSString).substring(with: m.range(at: 3))
                    conditions.append(.contains(variable, prop, value))
                }
                continue
            }

            // var.prop = "value"
            if let eqMatch = trimmed.range(of: #"(\w+)\.(\w+)\s*=\s*"([^"]*)""#, options: .regularExpression) {
                let matched = String(trimmed[eqMatch])
                let regex = try! NSRegularExpression(pattern: #"(\w+)\.(\w+)\s*=\s*"([^"]*)""#)
                if let m = regex.firstMatch(in: matched, range: NSRange(matched.startIndex..., in: matched)) {
                    let variable = (matched as NSString).substring(with: m.range(at: 1))
                    let prop = (matched as NSString).substring(with: m.range(at: 2))
                    let value = (matched as NSString).substring(with: m.range(at: 3))
                    conditions.append(.equals(variable, prop, value))
                }
            }
        }

        return conditions
    }

    // MARK: - Execution

    private static func executePattern(
        pattern: Pattern,
        conditions: [ConditionOp],
        returnVars: [String],
        engine: GraphEngine
    ) throws -> CypherResult {
        // Single node pattern: MATCH (r:Label) WHERE ... RETURN r
        if pattern.nodes.count == 1 && pattern.edges.isEmpty {
            let pNode = pattern.nodes[0]
            let candidates = pNode.label.map { engine.findByLabel($0) } ?? Array(engine.allNodes.values)
            let filtered = candidates.filter { node in
                checkConditions(conditions, bindings: [pNode.variable: node])
            }
            return buildResult(filtered.map { [pNode.variable: $0] }, returnVars: returnVars)
        }

        // Two-node pattern: MATCH (a:L)-[:E]->(b:L) WHERE ... RETURN ...
        if pattern.nodes.count == 2 && pattern.edges.count == 1 {
            let srcPattern = pattern.nodes[0]
            let tgtPattern = pattern.nodes[1]
            let edgePattern = pattern.edges[0]

            let srcCandidates = srcPattern.label.map { engine.findByLabel($0) } ?? Array(engine.allNodes.values)

            var bindings: [[String: GraphNode]] = []

            for srcNode in srcCandidates {
                for edge in srcNode.edges {
                    if let et = edgePattern.edgeType, edge.type != et { continue }

                    let tgtNode: GraphNode?
                    switch edgePattern.direction {
                    case .outgoing:
                        tgtNode = (edge.source === srcNode) ? edge.target : nil
                    case .incoming:
                        tgtNode = (edge.target === srcNode) ? edge.source : nil
                    case .both:
                        tgtNode = (edge.source === srcNode) ? edge.target : edge.source
                    }

                    guard let target = tgtNode else { continue }
                    if let tgtLabel = tgtPattern.label, target.label != tgtLabel { continue }

                    let binding = [srcPattern.variable: srcNode, tgtPattern.variable: target]
                    if checkConditions(conditions, bindings: binding) {
                        bindings.append(binding)
                    }
                }
            }

            return buildResult(bindings, returnVars: returnVars)
        }

        throw CypherError.parseFailed("Unsupported pattern complexity")
    }

    private static func checkConditions(_ conditions: [ConditionOp], bindings: [String: GraphNode]) -> Bool {
        for condition in conditions {
            switch condition {
            case .equals(let variable, let prop, let value):
                guard let node = bindings[variable] else { return false }
                guard node.properties[prop] == value else { return false }
            case .contains(let variable, let prop, let substring):
                guard let node = bindings[variable] else { return false }
                guard let propVal = node.properties[prop], propVal.contains(substring) else { return false }
            }
        }
        return true
    }

    private static func buildResult(_ bindings: [[String: GraphNode]], returnVars: [String]) -> CypherResult {
        var columns: Set<String> = []
        var rows: [[String: String]] = []

        for binding in bindings {
            var row: [String: String] = [:]
            for varName in returnVars {
                if let node = binding[varName] {
                    for (key, value) in node.properties {
                        let col = "\(varName).\(key)"
                        columns.insert(col)
                        row[col] = value
                    }
                    row["\(varName).id"] = String(node.id)
                    columns.insert("\(varName).id")
                    row["\(varName).label"] = node.label.displayName
                    columns.insert("\(varName).label")
                }
            }
            rows.append(row)
        }

        return CypherResult(columns: columns.sorted(), rows: rows)
    }
}
