import Foundation
import GRDB

struct ReaderLibraryPaths: Sendable {
    let rootURL: URL

    var databaseURL: URL {
        rootURL.appending(path: "library.sqlite")
    }

    var importsURL: URL {
        rootURL.appending(path: "Imports", directoryHint: .isDirectory)
    }

    static func live() throws -> ReaderLibraryPaths {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return ReaderLibraryPaths(
            rootURL: applicationSupport
                .appending(path: "Reader", directoryHint: .isDirectory)
        )
    }
}

struct StoredReadingState: Equatable, Sendable {
    let locator: ReaderLocator?
    let progress: Double
    let lastOpenedAt: Date?
    let updatedAt: Date
}

struct StoredReadingRecord: Equatable, Sendable {
    let publicationID: UUID
    let state: StoredReadingState
}

struct DeviceReaderPreferences: Equatable, Sendable {
    let scale: Double
    let pdfScaleMode: String
    let scrollMode: String

    init(
        scale: Double,
        pdfScaleMode: String = "manual",
        scrollMode: String = "continuous"
    ) {
        self.scale = scale
        self.pdfScaleMode = pdfScaleMode
        self.scrollMode = scrollMode
    }
}

enum ReaderLibraryStoreError: LocalizedError {
    case unmanagedAsset(URL)
    case invalidRecord(String)

    var errorDescription: String? {
        switch self {
        case .unmanagedAsset(let url):
            "Reader can only persist managed library files. \(url.lastPathComponent) is outside the library."
        case .invalidRecord(let id):
            "Reader could not restore the saved publication \(id)."
        }
    }
}

@MainActor
final class ReaderLibraryStore {
    let paths: ReaderLibraryPaths

    private let database: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL) throws {
        paths = ReaderLibraryPaths(rootURL: rootURL.standardizedFileURL)
        try FileManager.default.createDirectory(
            at: paths.rootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.importsURL,
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabaseQueue(
            path: paths.databaseURL.path,
            configuration: configuration
        )
        try Self.migrator.migrate(database)
    }

    static func live() throws -> ReaderLibraryStore {
        try ReaderLibraryStore(rootURL: ReaderLibraryPaths.live().rootURL)
    }

    func loadBooks() throws -> [Book] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    p.*,
                    COALESCE(r.progress, 0) AS saved_progress
                FROM publications p
                LEFT JOIN reading_state r ON r.publication_id = p.id
                ORDER BY p.sort_order ASC, p.imported_at ASC
                """
            )
            return try rows.map(book(from:))
        }
    }

    /// Adopts managed publication files created before the SQLite catalogue
    /// existed. Individual unreadable files are left in place and do not stop
    /// the rest of the library from opening.
    func reconcileManagedImports() throws {
        var knownFingerprints = Set(
            try loadBooks().compactMap { $0.publication?.fingerprint }
        )
        let supportedExtensions = Set(["pdf", "epub", "txt", "text"])
        let fingerprintDirectories = try FileManager.default.contentsOfDirectory(
            at: paths.importsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for directory in fingerprintDirectories.sorted(by: { $0.path < $1.path }) {
            guard
                (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                !knownFingerprints.contains(directory.lastPathComponent)
            else {
                continue
            }

            let candidates = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for sourceURL in candidates.sorted(by: { $0.path < $1.path })
            where supportedExtensions.contains(sourceURL.pathExtension.lowercased()) {
                do {
                    let book = try PublicationImportService.importBook(
                        from: sourceURL,
                        libraryRoot: paths.rootURL
                    )
                    guard
                        let fingerprint = book.publication?.fingerprint,
                        !knownFingerprints.contains(fingerprint)
                    else {
                        continue
                    }
                    try saveImportedBook(book)
                    knownFingerprints.insert(fingerprint)
                } catch {
                    continue
                }
            }
        }
    }

    func saveImportedBook(_ book: Book, importedAt: Date = .now) throws {
        guard let publication = book.publication else {
            throw ReaderLibraryStoreError.invalidRecord(book.id.uuidString)
        }
        let assetPath = try relativePath(for: publication.sourceURL)
        let coverPath = try publication.coverURL.map(relativePath(for:))
        let readingLength = storageValue(for: book.readingLength)

        try database.write { db in
            let nextSortOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM publications"
            ) ?? 0
            try db.execute(
                sql: """
                INSERT INTO publications (
                    id, fingerprint, title, author, format, asset_path,
                    cover_path, cover_style, reading_length_kind,
                    reading_length_value, imported_at, sort_order
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    book.id.uuidString,
                    publication.fingerprint,
                    book.title,
                    book.author,
                    publication.format.rawValue,
                    assetPath,
                    coverPath,
                    book.coverStyle.rawValue,
                    readingLength.kind,
                    readingLength.value,
                    importedAt.timeIntervalSince1970,
                    nextSortOrder
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO reading_state (
                    publication_id, locator_json, progress,
                    last_opened_at, updated_at
                ) VALUES (?, NULL, ?, NULL, ?)
                """,
                arguments: [
                    book.id.uuidString,
                    book.progress,
                    importedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func saveBookOrder(_ publicationIDs: [UUID]) throws {
        try database.write { db in
            for (sortOrder, publicationID) in publicationIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE publications SET sort_order = ? WHERE id = ?",
                    arguments: [sortOrder, publicationID.uuidString]
                )
            }
        }
    }

    func loadReadingState(publicationID: UUID) throws -> StoredReadingState? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM reading_state WHERE publication_id = ?",
                arguments: [publicationID.uuidString]
            ) else {
                return nil
            }
            let locatorData: Data? = row["locator_json"]
            return StoredReadingState(
                locator: try locatorData.map { try decoder.decode(ReaderLocator.self, from: $0) },
                progress: row["progress"],
                lastOpenedAt: Self.date(from: row["last_opened_at"] as Double?),
                updatedAt: Self.date(from: row["updated_at"] as Double?) ?? .distantPast
            )
        }
    }

    func loadMostRecentReadingRecord() throws -> StoredReadingRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM reading_state
                WHERE last_opened_at IS NOT NULL
                ORDER BY last_opened_at DESC
                LIMIT 1
                """
            ) else { return nil }
            guard let publicationID = UUID(uuidString: row["publication_id"]) else {
                throw ReaderLibraryStoreError.invalidRecord(row["publication_id"])
            }
            let locatorData: Data? = row["locator_json"]
            return StoredReadingRecord(
                publicationID: publicationID,
                state: StoredReadingState(
                    locator: try locatorData.map {
                        try decoder.decode(ReaderLocator.self, from: $0)
                    },
                    progress: row["progress"],
                    lastOpenedAt: Self.date(from: row["last_opened_at"] as Double?),
                    updatedAt: Self.date(from: row["updated_at"] as Double?) ?? .distantPast
                )
            )
        }
    }

    func loadAllReadingRecords() throws -> [StoredReadingRecord] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM reading_state
                WHERE locator_json IS NOT NULL
                  AND last_opened_at IS NOT NULL
                ORDER BY last_opened_at DESC
                """
            )
            return try rows.map { row in
                guard let publicationID = UUID(
                    uuidString: row["publication_id"] as String
                ) else {
                    throw ReaderLibraryStoreError.invalidRecord(row["publication_id"])
                }
                let locatorData: Data = row["locator_json"]
                return StoredReadingRecord(
                    publicationID: publicationID,
                    state: StoredReadingState(
                        locator: try decoder.decode(ReaderLocator.self, from: locatorData),
                        progress: row["progress"],
                        lastOpenedAt: Self.date(from: row["last_opened_at"] as Double?),
                        updatedAt: Self.date(from: row["updated_at"] as Double?) ?? .distantPast
                    )
                )
            }
        }
    }

    func saveReadingState(
        publicationID: UUID,
        locator: ReaderLocator,
        progress: Double,
        openedAt: Date = .now
    ) throws {
        let locatorData = try encoder.encode(locator)
        let clampedProgress = min(max(progress, 0), 1)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO reading_state (
                    publication_id, locator_json, progress,
                    last_opened_at, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(publication_id) DO UPDATE SET
                    locator_json = excluded.locator_json,
                    progress = excluded.progress,
                    last_opened_at = excluded.last_opened_at,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    publicationID.uuidString,
                    locatorData,
                    clampedProgress,
                    openedAt.timeIntervalSince1970,
                    openedAt.timeIntervalSince1970
                ]
            )
        }
    }

    @discardableResult
    func mergeSyncedReadingRecords(
        _ records: [StoredReadingRecord]
    ) throws -> [StoredReadingRecord] {
        let encoded = try records.compactMap { record -> (StoredReadingRecord, Data)? in
            guard let locator = record.state.locator else { return nil }
            return (record, try encoder.encode(locator))
        }
        return try database.write { db in
            var applied: [StoredReadingRecord] = []
            for (record, locatorData) in encoded {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT locator_json, updated_at
                    FROM reading_state
                    WHERE publication_id = ?
                    """,
                    arguments: [record.publicationID.uuidString]
                )
                let localUpdatedAt = Self.date(from: row?["updated_at"] as Double?)
                let localLocatorData: Data? = row?["locator_json"]
                if
                    localLocatorData != nil,
                    let localUpdatedAt,
                    record.state.updatedAt <= localUpdatedAt
                {
                    continue
                }

                try db.execute(
                    sql: """
                    INSERT INTO reading_state (
                        publication_id, locator_json, progress,
                        last_opened_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(publication_id) DO UPDATE SET
                        locator_json = excluded.locator_json,
                        progress = excluded.progress,
                        last_opened_at = excluded.last_opened_at,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        record.publicationID.uuidString,
                        locatorData,
                        min(max(record.state.progress, 0), 1),
                        record.state.lastOpenedAt?.timeIntervalSince1970,
                        record.state.updatedAt.timeIntervalSince1970
                    ]
                )
                applied.append(record)
            }
            return applied
        }
    }

    func loadAnnotations(publicationID: UUID) throws -> [ReaderAnnotation] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM annotations
                WHERE publication_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [publicationID.uuidString]
            )
            return try rows.map { row in
                let locatorData: Data = row["locator_json"]
                guard let id = UUID(uuidString: row["id"] as String) else {
                    throw ReaderLibraryStoreError.invalidRecord(row["id"])
                }
                return ReaderAnnotation(
                    id: id,
                    publicationFingerprint: row["publication_fingerprint"],
                    locator: try decoder.decode(ReaderLocator.self, from: locatorData),
                    selectedText: row["selected_text"],
                    note: row["note"],
                    notePlacement: Self.notePlacement(from: row),
                    highlightColor: ReaderHighlightColor(
                        persistedValue: row["highlight_color"]
                    ) ?? .lemon,
                    createdAt: Self.date(from: row["created_at"] as Double?) ?? .distantPast,
                    updatedAt: Self.date(from: row["updated_at"] as Double?) ?? .distantPast
                )
            }
        }
    }

    func loadAllAnnotations() throws -> [ReaderAnnotation] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM annotations ORDER BY created_at ASC"
            )
            return try rows.map { row in
                let locatorData: Data = row["locator_json"]
                guard let id = UUID(uuidString: row["id"] as String) else {
                    throw ReaderLibraryStoreError.invalidRecord(row["id"])
                }
                return ReaderAnnotation(
                    id: id,
                    publicationFingerprint: row["publication_fingerprint"],
                    locator: try decoder.decode(ReaderLocator.self, from: locatorData),
                    selectedText: row["selected_text"],
                    note: row["note"],
                    notePlacement: Self.notePlacement(from: row),
                    highlightColor: ReaderHighlightColor(
                        persistedValue: row["highlight_color"]
                    ) ?? .lemon,
                    createdAt: Self.date(from: row["created_at"] as Double?) ?? .distantPast,
                    updatedAt: Self.date(from: row["updated_at"] as Double?) ?? .distantPast
                )
            }
        }
    }

    func saveAnnotation(_ annotation: ReaderAnnotation, publicationID: UUID) throws {
        let locatorData = try encoder.encode(annotation.locator)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO annotations (
                    id, publication_id, publication_fingerprint, locator_json,
                    selected_text, note, note_placement_x, note_placement_y,
                    highlight_color, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    locator_json = excluded.locator_json,
                    selected_text = excluded.selected_text,
                    note = excluded.note,
                    note_placement_x = excluded.note_placement_x,
                    note_placement_y = excluded.note_placement_y,
                    highlight_color = excluded.highlight_color,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    annotation.id.uuidString,
                    publicationID.uuidString,
                    annotation.publicationFingerprint,
                    locatorData,
                    annotation.selectedText,
                    annotation.note,
                    annotation.notePlacement?.horizontalOffset,
                    annotation.notePlacement?.verticalOffset,
                    annotation.highlightColor.rawValue,
                    annotation.createdAt.timeIntervalSince1970,
                    annotation.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func mergeSyncedAnnotations(_ annotations: [ReaderAnnotation]) throws {
        let encoded = try annotations.map { annotation in
            (annotation, try encoder.encode(annotation.locator))
        }
        try database.write { db in
            for (annotation, locatorData) in encoded {
                guard let publicationID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM publications WHERE fingerprint = ?",
                    arguments: [annotation.publicationFingerprint]
                ) else { continue }

                try db.execute(
                    sql: """
                    INSERT INTO annotations (
                        id, publication_id, publication_fingerprint, locator_json,
                        selected_text, note, highlight_color, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        publication_id = excluded.publication_id,
                        publication_fingerprint = excluded.publication_fingerprint,
                        locator_json = excluded.locator_json,
                        selected_text = excluded.selected_text,
                        note = excluded.note,
                        highlight_color = excluded.highlight_color,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    WHERE annotations.updated_at <= excluded.updated_at
                    """,
                    arguments: [
                        annotation.id.uuidString,
                        publicationID,
                        annotation.publicationFingerprint,
                        locatorData,
                        annotation.selectedText,
                        annotation.note,
                        annotation.highlightColor.rawValue,
                        annotation.createdAt.timeIntervalSince1970,
                        annotation.updatedAt.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    func loadConversations() throws -> [ReaderConversation] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY created_at DESC"
            )
            return try rows.map { row in
                guard let id = UUID(uuidString: row["id"] as String) else {
                    throw ReaderLibraryStoreError.invalidRecord(row["id"])
                }
                let publicationID = (row["publication_id"] as String?).flatMap(UUID.init)
                let locatorData: Data? = row["locator_json"]
                return ReaderConversation(
                    id: id,
                    publicationID: publicationID,
                    publicationTitle: row["publication_title"],
                    question: row["question"],
                    answer: row["answer"],
                    locator: try locatorData.map {
                        try decoder.decode(ReaderLocator.self, from: $0)
                    },
                    createdAt: Self.date(from: row["created_at"] as Double?) ?? .distantPast
                )
            }
        }
    }

    func saveConversation(_ conversation: ReaderConversation) throws {
        let locatorData = try conversation.locator.map(encoder.encode)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversations (
                    id, publication_id, publication_title, question,
                    answer, locator_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    question = excluded.question,
                    answer = excluded.answer
                """,
                arguments: [
                    conversation.id.uuidString,
                    conversation.publicationID?.uuidString,
                    conversation.publicationTitle,
                    conversation.question,
                    conversation.answer,
                    locatorData,
                    conversation.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    func loadDevicePreferences(publicationID: UUID) throws -> DeviceReaderPreferences? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM device_reader_preferences WHERE publication_id = ?",
                arguments: [publicationID.uuidString]
            ) else {
                return nil
            }
            return DeviceReaderPreferences(
                scale: row["scale"],
                pdfScaleMode: row["pdf_scale_mode"],
                scrollMode: row["scroll_mode"]
            )
        }
    }

    func saveDevicePreferences(
        _ preferences: DeviceReaderPreferences,
        publicationID: UUID,
        updatedAt: Date = .now
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO device_reader_preferences (
                    publication_id, scale, pdf_scale_mode,
                    scroll_mode, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(publication_id) DO UPDATE SET
                    scale = excluded.scale,
                    pdf_scale_mode = excluded.pdf_scale_mode,
                    scroll_mode = excluded.scroll_mode,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    publicationID.uuidString,
                    preferences.scale,
                    preferences.pdfScaleMode,
                    preferences.scrollMode,
                    updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func tableNames() throws -> Set<String> {
        try database.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            )
        }
    }

    private func book(from row: Row) throws -> Book {
        guard
            let id = UUID(uuidString: row["id"] as String),
            let format = PublicationFormat(rawValue: row["format"] as String),
            let coverStyle = BookCoverStyle(rawValue: row["cover_style"] as String),
            let readingLength = readingLength(
                kind: row["reading_length_kind"],
                value: row["reading_length_value"]
            )
        else {
            throw ReaderLibraryStoreError.invalidRecord(row["id"])
        }

        let assetPath: String = row["asset_path"]
        let coverPath: String? = row["cover_path"]
        return Book(
            id: id,
            title: row["title"],
            author: row["author"],
            progress: row["saved_progress"],
            coverStyle: coverStyle,
            formatLabel: format.displayName,
            readingLength: readingLength,
            sample: sample(for: format, readingLength: readingLength),
            publication: PublicationReference(
                sourceURL: paths.rootURL.appending(path: assetPath),
                format: format,
                fingerprint: row["fingerprint"],
                coverURL: coverPath.map { paths.rootURL.appending(path: $0) }
            )
        )
    }

    private func relativePath(for url: URL) throws -> String {
        let rootPath = paths.rootURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else {
            throw ReaderLibraryStoreError.unmanagedAsset(url)
        }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    private func storageValue(for length: ReadingLength) -> (kind: String, value: Int?) {
        switch length {
        case .pages(let count):
            ("pages", count)
        case .estimatedPages(let count):
            ("estimatedPages", count)
        case .reflowable:
            ("reflowable", nil)
        }
    }

    private func readingLength(kind: String, value: Int?) -> ReadingLength? {
        switch kind {
        case "pages":
            value.map(ReadingLength.pages)
        case "estimatedPages":
            value.map(ReadingLength.estimatedPages)
        case "reflowable":
            .reflowable
        default:
            nil
        }
    }

    private func sample(
        for format: PublicationFormat,
        readingLength: ReadingLength
    ) -> ReadingSample {
        switch format {
        case .pdf:
            ReadingSample(
                chapter: readingLength.displayLabel,
                section: "Fixed-layout PDF",
                paragraphs: []
            )
        case .epub:
            ReadingSample(
                chapter: readingLength.displayLabel,
                section: "Reflowable EPUB",
                paragraphs: []
            )
        case .plainText:
            ReadingSample(
                chapter: "Plain text",
                section: "Reflowable text",
                paragraphs: []
            )
        }
    }

    private static func date(from timestamp: Double?) -> Date? {
        timestamp.map(Date.init(timeIntervalSince1970:))
    }

    private static func notePlacement(from row: Row) -> ReaderNotePlacement? {
        guard
            let horizontalOffset = row["note_placement_x"] as Double?,
            let verticalOffset = row["note_placement_y"] as Double?
        else { return nil }
        return ReaderNotePlacement(
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-local-library") { db in
            try db.create(table: "publications") { table in
                table.column("id", .text).primaryKey()
                table.column("fingerprint", .text).notNull().unique()
                table.column("title", .text).notNull()
                table.column("author", .text).notNull()
                table.column("format", .text).notNull()
                table.column("asset_path", .text).notNull()
                table.column("cover_path", .text)
                table.column("cover_style", .text).notNull()
                table.column("reading_length_kind", .text).notNull()
                table.column("reading_length_value", .integer)
                table.column("imported_at", .double).notNull()
            }

            try db.create(table: "reading_state") { table in
                table.column("publication_id", .text)
                    .primaryKey()
                    .references("publications", onDelete: .cascade)
                table.column("locator_json", .blob)
                table.column("progress", .double).notNull().defaults(to: 0)
                table.column("last_opened_at", .double)
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "annotations") { table in
                table.column("id", .text).primaryKey()
                table.column("publication_id", .text)
                    .notNull()
                    .indexed()
                    .references("publications", onDelete: .cascade)
                table.column("publication_fingerprint", .text).notNull()
                table.column("locator_json", .blob).notNull()
                table.column("selected_text", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "device_reader_preferences") { table in
                table.column("publication_id", .text)
                    .primaryKey()
                    .references("publications", onDelete: .cascade)
                table.column("scale", .double).notNull()
                table.column("pdf_scale_mode", .text).notNull()
                table.column("scroll_mode", .text).notNull()
                table.column("updated_at", .double).notNull()
            }
        }
        migrator.registerMigration("v2-quiet-reader-lists") { db in
            try db.alter(table: "annotations") { table in
                table.add(column: "note", .text)
            }
            try db.create(table: "conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("publication_id", .text)
                    .references("publications", onDelete: .setNull)
                table.column("publication_title", .text).notNull()
                table.column("question", .text).notNull()
                table.column("answer", .text).notNull()
                table.column("locator_json", .blob)
                table.column("created_at", .double).notNull()
            }
        }
        migrator.registerMigration("v3-highlight-colors") { db in
            try db.alter(table: "annotations") { table in
                table.add(column: "highlight_color", .text)
                    .notNull()
                    .defaults(to: ReaderHighlightColor.lemon.rawValue)
            }
        }
        migrator.registerMigration("v4-rename-highlight-colors") { db in
            try db.execute(
                sql: """
                UPDATE annotations
                SET highlight_color = CASE highlight_color
                    WHEN 'sun' THEN 'lemon'
                    WHEN 'rose' THEN 'petal'
                    WHEN 'tide' THEN 'aqua'
                    ELSE highlight_color
                END
                """
            )
        }
        migrator.registerMigration("v5-note-placement") { db in
            try db.alter(table: "annotations") { table in
                table.add(column: "note_placement_x", .double)
                table.add(column: "note_placement_y", .double)
            }
        }
        migrator.registerMigration("v6-publication-sort-order") { db in
            try db.alter(table: "publications") { table in
                table.add(column: "sort_order", .integer)
                    .notNull()
                    .defaults(to: 0)
            }
            let publicationIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM publications ORDER BY imported_at ASC, id ASC"
            )
            for (sortOrder, publicationID) in publicationIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE publications SET sort_order = ? WHERE id = ?",
                    arguments: [sortOrder, publicationID]
                )
            }
        }
        return migrator
    }
}
