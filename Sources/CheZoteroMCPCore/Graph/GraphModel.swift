import Foundation

// MARK: - Node Labels

public enum NodeLabel: UInt8, CaseIterable, Sendable {
    case researcher  = 0
    case paper       = 1
    case institution = 2
    case journal     = 3

    public var displayName: String {
        switch self {
        case .researcher:  return "Researcher"
        case .paper:       return "Paper"
        case .institution: return "Institution"
        case .journal:     return "Journal"
        }
    }
}

// MARK: - Edge Types

public enum EdgeType: UInt8, CaseIterable, Sendable {
    case authored       = 0
    case coAuthor       = 1
    case publishedIn    = 2
    case affiliatedWith = 3
    case cites          = 4
    case advisorOf      = 5

    public var displayName: String {
        switch self {
        case .authored:       return "AUTHORED"
        case .coAuthor:       return "CO_AUTHOR"
        case .publishedIn:    return "PUBLISHED_IN"
        case .affiliatedWith: return "AFFILIATED_WITH"
        case .cites:          return "CITES"
        case .advisorOf:      return "ADVISOR_OF"
        }
    }
}

// MARK: - Graph Node

public final class GraphNode {
    public let id: UInt32
    public let label: NodeLabel
    public var properties: [String: String]
    public var edges: [GraphEdge]

    public init(id: UInt32, label: NodeLabel, properties: [String: String]) {
        self.id = id
        self.label = label
        self.properties = properties
        self.edges = []
    }

    public func neighbors(direction: EdgeDirection = .both, edgeType: EdgeType? = nil) -> [GraphNode] {
        var result: [GraphNode] = []
        for edge in edges {
            if let et = edgeType, edge.type != et { continue }
            switch direction {
            case .outgoing:
                if edge.source === self { result.append(edge.target) }
            case .incoming:
                if edge.target === self { result.append(edge.source) }
            case .both:
                if edge.source === self { result.append(edge.target) }
                else if edge.target === self { result.append(edge.source) }
            }
        }
        return result
    }

    public var degree: Int { edges.count }
}

extension GraphNode: Hashable {
    public static func == (lhs: GraphNode, rhs: GraphNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Graph Edge

public final class GraphEdge {
    public let id: UInt32
    public let type: EdgeType
    public unowned let source: GraphNode
    public unowned let target: GraphNode
    public var properties: [String: String]

    public init(id: UInt32, type: EdgeType, source: GraphNode, target: GraphNode, properties: [String: String]) {
        self.id = id
        self.type = type
        self.source = source
        self.target = target
        self.properties = properties
    }
}

extension GraphEdge: Hashable {
    public static func == (lhs: GraphEdge, rhs: GraphEdge) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Direction

public enum EdgeDirection {
    case outgoing  // source → target
    case incoming  // target → source
    case both
}
