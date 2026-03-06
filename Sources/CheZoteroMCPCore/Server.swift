// Sources/CheZoteroMCPCore/Server.swift
import Foundation
import MCP

public class CheZoteroMCPServer {
    let server: Server
    let transport: StdioTransport
    let tools: [Tool]
    let reader: ZoteroReader
    let embeddings: EmbeddingManager
    let academic: AcademicSearchClient
    let orcid: OrcidClient
    let doiResolver: DOIResolver
    let webAPI: ZoteroWebAPI?
    let config: ConfigManager

    public init() async throws {
        reader = try ZoteroReader()
        embeddings = EmbeddingManager()
        academic = AcademicSearchClient()
        orcid = OrcidClient()
        doiResolver = DOIResolver(academic: academic)
        config = try ConfigManager()

        // Try to initialize Web API (requires ZOTERO_API_KEY env var)
        webAPI = try? await ZoteroWebAPI.createFromEnvironment()

        tools = Self.defineTools(hasWebAPI: webAPI != nil)

        server = Server(
            name: "che-zotero-mcp",
            version: "1.13.0",
            capabilities: .init(tools: .init())
        )

        transport = StdioTransport()
        await registerHandlers()
    }

    public func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    private static func defineTools(hasWebAPI: Bool = false) -> [Tool] {
        var allTools: [Tool] = [
            // --- Group Library Tools (1) ---
            Tool(
                name: "zotero_list_groups",
                description: "[YOUR LIBRARY] List all Zotero group libraries you have access to. Returns group IDs and names. Use the group_id from these results with other tools to operate on group libraries instead of your personal library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),

            // --- Zotero Library Tools (7) ---
            Tool(
                name: "zotero_search",
                description: "[YOUR LIBRARY] Search papers you've already saved in Zotero by keyword (title, creator, abstract, tags). Use when the user asks about papers in their collection. To discover NEW papers from global academic databases, use academic_search instead. Set group_id to search a group library instead of your personal library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10)")
                        ]),
                        "group_id": .object([
                            "type": .string("integer"),
                            "description": .string("Group ID to search in a group library (optional, default: personal library). Use zotero_list_groups to find group IDs.")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "zotero_get_my_publications",
                description: "[YOUR LIBRARY] List items in your Zotero \"My Publications\" collection — your own authored works. Reads local database first; automatically falls back to Zotero Web API if the database is locked (e.g., Zotero desktop is running). This is NOT a search tool — it returns a curated list you maintain in Zotero.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 100)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_get_metadata",
                description: "[YOUR LIBRARY] Get detailed metadata for an item in your Zotero library by its key",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),
            Tool(
                name: "zotero_get_collections",
                description: "[YOUR LIBRARY] List all collections in your Zotero library. Set group_id to list collections in a group library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "group_id": .object([
                            "type": .string("integer"),
                            "description": .string("Group ID for group library (optional, default: personal library)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_get_tags",
                description: "[YOUR LIBRARY] List all tags in your Zotero library with usage counts. Set group_id for group library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "group_id": .object([
                            "type": .string("integer"),
                            "description": .string("Group ID for group library (optional, default: personal library)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_get_recent",
                description: "[YOUR LIBRARY] Get recently added items in your Zotero library. Set group_id for group library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Number of recent items (default: 10)")
                        ]),
                        "group_id": .object([
                            "type": .string("integer"),
                            "description": .string("Group ID for group library (optional, default: personal library)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_semantic_search",
                description: "[YOUR LIBRARY] Semantic search within your saved Zotero papers using MLX embeddings (BAAI/bge-m3). Finds items by meaning, not just keywords — useful when the user can't recall exact titles. Requires zotero_build_index first. To discover NEW papers by topic from external databases, use academic_search instead.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Natural language search query")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "zotero_build_index",
                description: "[YOUR LIBRARY] Build or rebuild the semantic search index from your Zotero library. Downloads the embedding model on first run (~1.5GB). Index is persisted to disk.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),

            // --- Enhanced Zotero Tools (3) ---
            Tool(
                name: "zotero_get_items_in_collection",
                description: "[YOUR LIBRARY] List all items in a specific Zotero collection by its key",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "collection_key": .object([
                            "type": .string("string"),
                            "description": .string("Collection key (use zotero_get_collections to find keys)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 50)")
                        ])
                    ]),
                    "required": .array([.string("collection_key")])
                ])
            ),
            Tool(
                name: "zotero_search_by_doi",
                description: "[YOUR LIBRARY] Check if a paper with a specific DOI exists in your saved Zotero items. Returns the item's metadata if found. Set group_id to search a group library.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doi": .object([
                            "type": .string("string"),
                            "description": .string("DOI to search for (with or without https://doi.org/ prefix)")
                        ]),
                        "group_id": .object([
                            "type": .string("integer"),
                            "description": .string("Group ID for group library (optional, default: personal library)")
                        ])
                    ]),
                    "required": .array([.string("doi")])
                ])
            ),
            Tool(
                name: "zotero_get_attachments",
                description: "[YOUR LIBRARY] Get PDF attachment file paths for a Zotero item",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),

            // --- Academic Search Tools (5) ---
            Tool(
                name: "academic_search",
                description: "[EXTERNAL DATABASE] Discover NEW papers from OpenAlex (250M+ global academic works). Searches the worldwide academic literature — NOT limited to your Zotero library. Returns titles, authors, year, citation count, DOI, and open access status. Use when the user wants to find, explore, or discover research on a topic. To search within your saved papers, use zotero_search or zotero_semantic_search instead.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query (keywords, topic, or paper title)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "academic_lookup_doi",
                description: "[EXTERNAL DATABASE] Look up a paper's full metadata from OpenAlex by DOI. Returns abstract, authors, affiliations, citation count, and open access info. This is read-only — it does NOT save the paper to Zotero. Use when the user wants information about a paper they haven't saved. To add a paper to Zotero by DOI, use zotero_add_item_by_doi. To check if a DOI is already in your library, use zotero_search_by_doi.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doi": .object([
                            "type": .string("string"),
                            "description": .string("DOI of the paper (with or without https://doi.org/ prefix)")
                        ])
                    ]),
                    "required": .array([.string("doi")])
                ])
            ),
            Tool(
                name: "academic_get_citations",
                description: "[EXTERNAL DATABASE] Get papers that cite a given work — forward citation tracking via OpenAlex. Use when exploring a paper's academic impact or finding follow-up research. Requires OpenAlex ID from academic_search or academic_lookup_doi results.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "openalex_id": .object([
                            "type": .string("string"),
                            "description": .string("OpenAlex work ID (e.g. 'W1234567890' or full URL)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("openalex_id")])
                ])
            ),
            Tool(
                name: "academic_get_references",
                description: "[EXTERNAL DATABASE] Get papers referenced by a given work — backward reference tracking via OpenAlex. Use when exploring a paper's theoretical foundations or finding seminal works. Requires OpenAlex ID from academic_search or academic_lookup_doi results.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "openalex_id": .object([
                            "type": .string("string"),
                            "description": .string("OpenAlex work ID (e.g. 'W1234567890' or full URL)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([.string("openalex_id")])
                ])
            ),
            Tool(
                name: "academic_search_author",
                description: "[EXTERNAL DATABASE] Search OpenAlex for papers by a specific author. Accepts three identifier types (priority: orcid > openalex_author_id > name). ORCID gives the most precise results; name search is fuzzy and may return papers by different people with similar names. At least one identifier must be provided. For a researcher's self-curated, authoritative list, use orcid_get_publications instead.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "orcid": .object([
                            "type": .string("string"),
                            "description": .string("ORCID ID (e.g. '0000-0003-3376-7833'). Most precise — filters by author.orcid")
                        ]),
                        "openalex_author_id": .object([
                            "type": .string("string"),
                            "description": .string("OpenAlex Author ID (e.g. 'A5073079707'). Precise but entity may include misattributed papers")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Author name (fallback). Fuzzy search — may return papers by different people with similar names")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Max results to return (default: 10, max: 50)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),

            // --- ORCID / Publication Import (2) ---
            Tool(
                name: "orcid_get_publications",
                description: "[EXTERNAL DATABASE] List publications from an ORCID profile (public data, no auth required). Returns the researcher's self-curated, authoritative publication list with titles, years, DOIs, and journal names. More accurate than name-based search for a specific researcher.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "orcid_id": .object([
                            "type": .string("string"),
                            "description": .string("ORCID ID (e.g. '0000-0003-3376-7833' or full URL)")
                        ])
                    ]),
                    "required": .array([.string("orcid_id")])
                ])
            ),
            Tool(
                name: "import_publications_to_zotero",
                description: "[BRIDGE: EXTERNAL → YOUR LIBRARY] Batch import publications into Zotero from external sources. Sources: 'orcid' (authoritative, user-curated — recommended for 'my publications'), 'openalex_orcid' (broader discovery via OpenAlex, may include false positives from name disambiguation), 'dois' (manual DOI list). Resolves metadata via DOIResolver cascade (OpenAlex → doi.org → Airiti). Supports dry_run preview and skip_existing to avoid duplicates.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "enum": .array([.string("orcid"), .string("openalex_orcid"), .string("dois")]),
                            "description": .string("Import source: 'orcid' (user-curated, most accurate), 'openalex_orcid' (broader but may have false positives), 'dois' (manual DOI list)")
                        ]),
                        "orcid_id": .object([
                            "type": .string("string"),
                            "description": .string("ORCID ID — required for 'orcid' and 'openalex_orcid' sources")
                        ]),
                        "dois": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("List of DOIs — required for 'dois' source")
                        ]),
                        "collection_key": .object([
                            "type": .string("string"),
                            "description": .string("Collection key to add imported items to (optional)")
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Tags to apply to imported items (optional)")
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("Preview only, don't actually create items (default: true)")
                        ]),
                        "skip_existing": .object([
                            "type": .string("boolean"),
                            "description": .string("Skip items already in Zotero library by DOI (default: true)")
                        ])
                    ]),
                    "required": .array([.string("source")])
                ])
            ),

            // --- Notes & Annotations (2) ---
            Tool(
                name: "zotero_get_notes",
                description: "[YOUR LIBRARY] Get all notes attached to a Zotero item (plain text, HTML stripped)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),
            Tool(
                name: "zotero_get_annotations",
                description: "[YOUR LIBRARY] Get PDF annotations (highlights, notes, underlines) for a Zotero item",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("item_key")])
                ])
            ),
            // --- Similarity (1) ---
            Tool(
                name: "academic_compare_papers",
                description: "[ANALYSIS] Compare two papers across 11 similarity dimensions. Returns a similarity vector: semantic (embedding cosine), bibliographic_coupling (Salton's cosine of shared references), adamic_adar (shared refs weighted by 1/log(cited_by) — rare shared refs score higher), resource_allocation (1/cited_by weighting), hub_promoted_index (shared/min), hub_depressed_index (shared/max), co_citation (shared citing papers), author_overlap, venue, tag_overlap, shortest_path (citation graph distance). Accepts DOI or Zotero item key.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "paper_a": .object([
                            "type": .string("string"),
                            "description": .string("First paper: DOI (e.g. '10.1016/j.metip.2021.100081') or Zotero item key")
                        ]),
                        "paper_b": .object([
                            "type": .string("string"),
                            "description": .string("Second paper: DOI or Zotero item key")
                        ])
                    ]),
                    "required": .array([.string("paper_a"), .string("paper_b")])
                ])
            ),

            // --- Citation Formatting Tools (2) ---
            Tool(
                name: "zotero_to_biblatex_apa",
                description: "[YOUR LIBRARY · FORMAT] Convert Zotero items to biblatex-apa format (.bib). Output is compatible with \\usepackage[style=apa,backend=biber]{biblatex}. Handles all Zotero item types, subtitle splitting, date normalization, pages conversion, corporate authors, and proper BibLaTeX field mapping (JOURNALTITLE, NUMBER, etc.). Provide item_key (single), item_keys (multiple), or collection_key (all items in a collection).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Single Zotero item key")
                        ]),
                        "item_keys": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Multiple Zotero item keys")
                        ]),
                        "collection_key": .object([
                            "type": .string("string"),
                            "description": .string("Collection key — export all items in collection")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "zotero_to_apa",
                description: "[YOUR LIBRARY · FORMAT] Convert Zotero items to APA 7th Edition formatted text. Supports three output formats: 'reference' (default, formatted reference entries), 'citation' (parenthetical + narrative in-text citations with full reference), 'reference_list' (sorted reference list). Handles author formatting (1/2/3-20/21+ rules), sentence case, italics, edition ordinals, DOI priority, and all major item types.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "item_key": .object([
                            "type": .string("string"),
                            "description": .string("Single Zotero item key")
                        ]),
                        "item_keys": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Multiple Zotero item keys")
                        ]),
                        "collection_key": .object([
                            "type": .string("string"),
                            "description": .string("Collection key — format all items in collection")
                        ]),
                        "format": .object([
                            "type": .string("string"),
                            "enum": .array([.string("reference"), .string("citation"), .string("reference_list")]),
                            "description": .string("Output format: 'reference' (default), 'citation' (parenthetical + narrative), 'reference_list' (alphabetical sorted list)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),

            // --- Config Tools (2) ---
            Tool(
                name: "zotero_set_config",
                description: "[CONFIG] Store a key-value pair in persistent config (~/.che-zotero-mcp/config.json). Use dot-notation keys for namespacing, e.g. 'my.orcid', 'researchers.advisor.orcid', 'researchers.advisor.openalex_author_id'. Stored values can be used by other tools as defaults (e.g. academic_search_author auto-fills from 'my.orcid'). To delete a key, use action='delete'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "key": .object([
                            "type": .string("string"),
                            "description": .string("Config key (e.g. 'my.orcid', 'researchers.advisor.name')")
                        ]),
                        "value": .object([
                            "type": .string("string"),
                            "description": .string("Value to store (omit when action='delete')")
                        ]),
                        "action": .object([
                            "type": .string("string"),
                            "enum": .array([.string("set"), .string("delete")]),
                            "description": .string("Action: 'set' (default) or 'delete'")
                        ])
                    ]),
                    "required": .array([.string("key")])
                ])
            ),
            Tool(
                name: "zotero_get_config",
                description: "[CONFIG] Read persistent config values. Without a key, returns all stored config. With a key, returns that specific value. Config is stored at ~/.che-zotero-mcp/config.json and persists across server restarts.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "key": .object([
                            "type": .string("string"),
                            "description": .string("Config key to read (optional — omit to get all)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ),
        ]

        // --- Write Tools (require ZOTERO_API_KEY) ---
        if hasWebAPI {
            allTools.append(contentsOf: [
                Tool(
                    name: "zotero_create_collection",
                    description: "[YOUR LIBRARY · WRITE] Create a new collection in your Zotero library (via Web API). Set group_id for group library.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .string("string"),
                                "description": .string("Collection name")
                            ]),
                            "parent_key": .object([
                                "type": .string("string"),
                                "description": .string("Parent collection key (optional, omit for top-level)")
                            ]),
                            "group_id": .object([
                                "type": .string("integer"),
                                "description": .string("Group ID for group library (optional, default: personal library)")
                            ])
                        ]),
                        "required": .array([.string("name")])
                    ])
                ),
                Tool(
                    name: "zotero_add_item_by_doi",
                    description: "[YOUR LIBRARY · WRITE] Add a paper to your Zotero library by DOI. Resolves metadata from external sources (OpenAlex → doi.org → Airiti) and creates a new item. Skips if DOI already exists (idempotent). Set group_id for group library.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "doi": .object([
                                "type": .string("string"),
                                "description": .string("DOI of the paper (with or without https://doi.org/ prefix)")
                            ]),
                            "collection_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Collection keys to add the item to (optional)")
                            ]),
                            "tags": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Tags to apply (optional)")
                            ]),
                            "group_id": .object([
                                "type": .string("integer"),
                                "description": .string("Group ID for group library (optional, default: personal library)")
                            ])
                        ]),
                        "required": .array([.string("doi")])
                    ])
                ),
                Tool(
                    name: "zotero_create_item",
                    description: "[YOUR LIBRARY · WRITE] Create a new item in your Zotero library with explicit fields (via Web API). For adding by DOI with auto-fill, use zotero_add_item_by_doi instead.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_type": .object([
                                "type": .string("string"),
                                "description": .string("Item type (e.g. journalArticle, book, conferencePaper, thesis, report)")
                            ]),
                            "title": .object([
                                "type": .string("string"),
                                "description": .string("Item title")
                            ]),
                            "creators": .object([
                                "type": .string("array"),
                                "items": .object([
                                    "type": .string("object"),
                                    "properties": .object([
                                        "firstName": .object(["type": .string("string")]),
                                        "lastName": .object(["type": .string("string")])
                                    ])
                                ]),
                                "description": .string("Authors as [{firstName, lastName}] (optional)")
                            ]),
                            "doi": .object([
                                "type": .string("string"),
                                "description": .string("DOI (optional)")
                            ]),
                            "publication_title": .object([
                                "type": .string("string"),
                                "description": .string("Journal/conference name (optional)")
                            ]),
                            "date": .object([
                                "type": .string("string"),
                                "description": .string("Publication date (optional)")
                            ]),
                            "abstract": .object([
                                "type": .string("string"),
                                "description": .string("Abstract (optional)")
                            ]),
                            "collection_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Collection keys (optional)")
                            ]),
                            "tags": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Tags (optional)")
                            ])
                        ]),
                        "required": .array([.string("item_type"), .string("title")])
                    ])
                ),
                Tool(
                    name: "zotero_add_to_collection",
                    description: "[YOUR LIBRARY · WRITE] Add an existing Zotero item to a collection (via Web API)",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_key": .object([
                                "type": .string("string"),
                                "description": .string("Zotero item key")
                            ]),
                            "collection_key": .object([
                                "type": .string("string"),
                                "description": .string("Collection key to add the item to")
                            ])
                        ]),
                        "required": .array([.string("item_key"), .string("collection_key")])
                    ])
                ),
                Tool(
                    name: "zotero_add_attachment",
                    description: "[YOUR LIBRARY · WRITE] Upload a local file (PDF, etc.) as attachment to a Zotero item via Web API. Supports PDF, EPUB, HTML, PNG, JPG. The file is uploaded to Zotero cloud storage.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_key": .object([
                                "type": .string("string"),
                                "description": .string("Parent item key to attach the file to")
                            ]),
                            "file_path": .object([
                                "type": .string("string"),
                                "description": .string("Absolute path to the local file")
                            ]),
                            "title": .object([
                                "type": .string("string"),
                                "description": .string("Attachment title (optional, defaults to filename)")
                            ])
                        ]),
                        "required": .array([.string("item_key"), .string("file_path")])
                    ])
                ),
                Tool(
                    name: "zotero_set_in_my_publications",
                    description: "[YOUR LIBRARY · WRITE] Add or remove an item from your Zotero \"My Publications\" collection (via Web API). \"My Publications\" is Zotero's built-in curated list of your own authored works — it's NOT a regular collection. Set in_publications=true to add, false to remove.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_key": .object([
                                "type": .string("string"),
                                "description": .string("Zotero item key")
                            ]),
                            "in_publications": .object([
                                "type": .string("boolean"),
                                "description": .string("true to add to My Publications, false to remove (default: true)")
                            ])
                        ]),
                        "required": .array([.string("item_key")])
                    ])
                ),
                Tool(
                    name: "zotero_delete_item",
                    description: "[YOUR LIBRARY · WRITE] Delete an item from your Zotero library by its key (via Web API). Permanently removes the item and its child notes/attachments.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_key": .object([
                                "type": .string("string"),
                                "description": .string("Zotero item key to delete")
                            ])
                        ]),
                        "required": .array([.string("item_key")])
                    ])
                ),
                Tool(
                    name: "zotero_delete_collection",
                    description: "[YOUR LIBRARY · WRITE] Delete a collection from your Zotero library (via Web API). Only removes the collection container — items inside are NOT deleted. Use zotero_get_collections to find collection keys.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "collection_key": .object([
                                "type": .string("string"),
                                "description": .string("Collection key to delete (use zotero_get_collections to find keys)")
                            ])
                        ]),
                        "required": .array([.string("collection_key")])
                    ])
                ),
                Tool(
                    name: "zotero_normalize_titles",
                    description: "[YOUR LIBRARY · WRITE] Batch convert Title Case titles to sentence case with proper noun preservation. Most Zotero imports store titles in Title Case (from publishers), but APA 7 / biblatex-apa require sentence case. This tool: (1) detects Title Case titles, (2) converts to sentence case, (3) preserves proper nouns (countries, nationalities, eponyms like Bayesian/Freudian, acronyms). Use dry_run=true (default) to preview changes before writing. Provide item_keys or collection_key to select items.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "item_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Zotero item keys to normalize")
                            ]),
                            "collection_key": .object([
                                "type": .string("string"),
                                "description": .string("Collection key — normalize all items in collection")
                            ]),
                            "dry_run": .object([
                                "type": .string("boolean"),
                                "description": .string("Preview changes without writing (default: true). Set to false to apply changes via Zotero Web API.")
                            ])
                        ]),
                        "required": .array([])
                    ])
                ),
                Tool(
                    name: "zotero_find_duplicates",
                    description: "[YOUR LIBRARY · WRITE] Detect and merge duplicate items. Two actions: (1) action='scan' — scan library/collection for duplicates, grouped by confidence: HIGH (same DOI), MEDIUM (similar title + author/year), LOW (near-identical title only). Returns groups with recommended item to keep. (2) action='merge' — merge specific duplicates: keep_key survives with merged tags/collections/fields, delete_keys are removed. Always scan first, confirm with user, then merge.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "action": .object([
                                "type": .string("string"),
                                "enum": .array([.string("scan"), .string("merge")]),
                                "description": .string("'scan' to find duplicates, 'merge' to combine items")
                            ]),
                            "collection_key": .object([
                                "type": .string("string"),
                                "description": .string("Scan within a specific collection (optional, default: entire library)")
                            ]),
                            "item_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Scan specific items only (optional)")
                            ]),
                            "keep_key": .object([
                                "type": .string("string"),
                                "description": .string("For merge: item key to keep (receives merged tags/collections/fields)")
                            ]),
                            "delete_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("For merge: item keys to merge into keep_key and then delete")
                            ])
                        ]),
                        "required": .array([.string("action")])
                    ])
                ),
            ])
        }

        return allTools
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await self.handleToolCall(params)
        }
    }

    private func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            switch params.name {
            // Group Library Tools
            case "zotero_list_groups":
                return try handleListGroups()

            // Zotero Library Tools
            case "zotero_search":
                return try handleSearch(params)
            case "zotero_get_my_publications":
                return try await handleGetMyPublications(params)
            case "zotero_get_metadata":
                return try handleGetMetadata(params)
            case "zotero_get_collections":
                return try handleGetCollections(params)
            case "zotero_get_tags":
                return try handleGetTags(params)
            case "zotero_get_recent":
                return try handleGetRecent(params)
            case "zotero_semantic_search":
                return try await handleSemanticSearch(params)
            case "zotero_build_index":
                return try await handleBuildIndex()

            // Enhanced Zotero Tools
            case "zotero_get_items_in_collection":
                return try handleGetItemsInCollection(params)
            case "zotero_search_by_doi":
                return try handleSearchByDOI(params)
            case "zotero_get_attachments":
                return try handleGetAttachments(params)

            // Academic Search Tools
            case "academic_search":
                return try await handleAcademicSearch(params)
            case "academic_lookup_doi":
                return try await handleAcademicGetPaper(params)
            case "academic_get_citations":
                return try await handleAcademicGetCitations(params)
            case "academic_get_references":
                return try await handleAcademicGetReferences(params)
            case "academic_search_author":
                return try await handleAcademicSearchAuthor(params)

            // ORCID / Publication Import
            case "orcid_get_publications":
                return try await handleOrcidGetPublications(params)
            case "import_publications_to_zotero":
                return try await handleImportPublications(params)

            // Notes & Annotations
            case "zotero_get_notes":
                return try handleGetNotes(params)
            case "zotero_get_annotations":
                return try handleGetAnnotations(params)

            // Similarity
            case "academic_compare_papers":
                return try await handleComparePapers(params)

            // Citation Formatting Tools
            case "zotero_to_biblatex_apa":
                return try handleToBiblatexAPA(params)
            case "zotero_to_apa":
                return try handleToAPA(params)

            // Config Tools
            case "zotero_set_config":
                return try handleSetConfig(params)
            case "zotero_get_config":
                return handleGetConfig(params)

            // Write Tools (Web API)
            case "zotero_create_collection":
                return try await handleCreateCollection(params)
            case "zotero_add_item_by_doi":
                return try await handleAddItemByDOI(params)
            case "zotero_create_item":
                return try await handleCreateItem(params)
            case "zotero_add_to_collection":
                return try await handleAddToCollection(params)
            case "zotero_add_attachment":
                return try await handleAddAttachment(params)
            case "zotero_set_in_my_publications":
                return try await handleSetInPublications(params)
            case "zotero_delete_item":
                return try await handleDeleteItem(params)
            case "zotero_delete_collection":
                return try await handleDeleteCollection(params)
            case "zotero_normalize_titles":
                return try await handleNormalizeTitles(params)
            case "zotero_find_duplicates":
                return try await handleFindDuplicates(params)

            default:
                return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

}

