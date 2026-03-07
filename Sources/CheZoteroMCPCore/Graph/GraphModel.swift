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

// MARK: - Direction

public enum EdgeDirection {
    case outgoing  // source → target
    case incoming  // target → source
    case both
}
