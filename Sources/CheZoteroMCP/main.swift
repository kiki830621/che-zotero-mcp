// Sources/CheZoteroMCP/main.swift
import Foundation
import CheZoteroMCPCore

do {
    let server = try await CheZoteroMCPServer()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
