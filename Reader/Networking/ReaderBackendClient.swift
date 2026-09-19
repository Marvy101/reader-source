import Foundation

struct ReaderAuthUser: Codable, Equatable, Sendable {
    let id: String
    let email: String?
}

private extension Array where Element == ReaderBookKnowledgeSnapshot.Chunk {
    func chunked(
        maximumCount: Int,
        maximumCharacters: Int
    ) -> [[Element]] {
        var batches: [[Element]] = []
        var batch: [Element] = []
        var characters = 0

        for chunk in self {
            if !batch.isEmpty,
               batch.count >= maximumCount
                || characters + chunk.text.count > maximumCharacters {
                batches.append(batch)
                batch = []
                characters = 0
            }
            batch.append(chunk)
            characters += chunk.text.count
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}

struct ReaderAuthSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double?
    let user: ReaderAuthUser
}

struct ReaderSignUpResult: Equatable, Sendable {
    let session: ReaderAuthSession?
    let user: ReaderAuthUser?
    let requiresEmailConfirmation: Bool
}

struct ReaderLibraryFileUpload: Equatable, Sendable {
    let publicationID: UUID
    let displayName: String
    let sourceURL: URL
    let mediaType: String
    let byteSize: Int
    let sha256: String
}

enum ReaderBackendError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case endpointUnavailable
    case networkUnavailable
    case secureConnectionFailed
    case serviceUnavailable
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Reader's online service is not configured."
        case .invalidResponse:
            "Reader received an invalid response from its online service."
        case .endpointUnavailable:
            "Reader's AI service needs to be updated. Try again in a moment."
        case .networkUnavailable:
            "Reader couldn't reach its AI service. Check your internet connection and try again."
        case .secureConnectionFailed:
            "Reader couldn't establish a secure connection to its AI service. Check your connection and try again."
        case .serviceUnavailable:
            "Reader's AI service is temporarily unavailable. Try again in a moment."
        case .server(_, let message):
            message
        }
    }

    var isUnauthorized: Bool {
        guard case .server(let code, _) = self else { return false }
        return code == "unauthorized" || code == "invalid_refresh_token"
    }
}

struct ReaderCloudReadingState: Equatable, Sendable {
    let fileID: UUID
    let locator: ReaderLocator
    let progress: Double
    let lastOpenedAt: Date
    let updatedAt: Date
}

protocol ReaderBackendServicing: Sendable {
    func signIn(email: String, password: String) async throws -> ReaderAuthSession
    func signUp(email: String, password: String) async throws -> ReaderSignUpResult
    func refreshSession(refreshToken: String) async throws -> ReaderAuthSession
    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest,
        accessToken: String
    ) async throws -> HighlightQuestionAnswer
    func syncAnnotations(
        _ annotations: [ReaderAnnotation],
        accessToken: String
    ) async throws -> [ReaderAnnotation]
    func libraryOrganization(
        accessToken: String
    ) async throws -> ReaderLibraryOrganization
    func createLibrary(
        name: String,
        parentID: UUID?,
        accessToken: String
    ) async throws -> ReaderLibraryFolder
    func renameLibrary(
        _ libraryID: UUID,
        name: String,
        accessToken: String
    ) async throws -> ReaderLibraryFolder
    func deleteLibrary(
        _ libraryID: UUID,
        accessToken: String
    ) async throws
    func moveLibraryFile(
        _ fileID: UUID,
        to folderID: UUID?,
        accessToken: String
    ) async throws -> ReaderLibraryFile
    func saveLibraryFileOrder(
        _ fileIDs: [UUID],
        accessToken: String
    ) async throws
    func streamChat(
        _ request: ReaderChatRequest,
        accessToken: String
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error>
    func generateChatTitle(
        _ request: ReaderChatTitleRequest,
        accessToken: String
    ) async throws -> ReaderChatTitle
    func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest,
        accessToken: String
    ) async throws
    func syncLibraryFile(
        _ upload: ReaderLibraryFileUpload,
        accessToken: String
    ) async throws
    func downloadLibraryFile(
        _ fileID: UUID,
        accessToken: String
    ) async throws -> URL
    func searchCatalog(
        query: String,
        locale: String,
        limit: Int,
        accessToken: String
    ) async throws -> [ReaderCatalogResult]
    func registerCatalogInterest(
        _ result: ReaderCatalogResult,
        emailOptIn: Bool,
        accessToken: String
    ) async throws
    func matchLibraryFile(
        _ publicationID: UUID,
        to result: ReaderCatalogResult,
        source: ReaderCatalogMatchSource,
        accessToken: String
    ) async throws
    func syncReadingStates(
        _ states: [ReaderCloudReadingState],
        deviceID: UUID,
        accessToken: String
    ) async throws -> [ReaderCloudReadingState]
}

extension ReaderBackendServicing {
    func syncAnnotations(
        _ annotations: [ReaderAnnotation],
        accessToken: String
    ) async throws -> [ReaderAnnotation] {
        throw ReaderBackendError.invalidConfiguration
    }

    func libraryOrganization(
        accessToken: String
    ) async throws -> ReaderLibraryOrganization {
        throw ReaderBackendError.invalidConfiguration
    }

    func createLibrary(
        name: String,
        parentID: UUID?,
        accessToken: String
    ) async throws -> ReaderLibraryFolder {
        throw ReaderBackendError.invalidConfiguration
    }

    func moveLibraryFile(
        _ fileID: UUID,
        to folderID: UUID?,
        accessToken: String
    ) async throws -> ReaderLibraryFile {
        throw ReaderBackendError.invalidConfiguration
    }

    func renameLibrary(
        _ libraryID: UUID,
        name: String,
        accessToken: String
    ) async throws -> ReaderLibraryFolder {
        throw ReaderBackendError.invalidConfiguration
    }

    func deleteLibrary(
        _ libraryID: UUID,
        accessToken: String
    ) async throws {
        throw ReaderBackendError.invalidConfiguration
    }

    func saveLibraryFileOrder(
        _ fileIDs: [UUID],
        accessToken: String
    ) async throws {
        throw ReaderBackendError.invalidConfiguration
    }

    func downloadLibraryFile(
        _ fileID: UUID,
        accessToken: String
    ) async throws -> URL {
        throw ReaderBackendError.invalidConfiguration
    }

    func searchCatalog(
        query: String,
        locale: String,
        limit: Int,
        accessToken: String
    ) async throws -> [ReaderCatalogResult] {
        throw ReaderBackendError.invalidConfiguration
    }

    func registerCatalogInterest(
        _ result: ReaderCatalogResult,
        emailOptIn: Bool,
        accessToken: String
    ) async throws {
        throw ReaderBackendError.invalidConfiguration
    }

    func syncReadingStates(
        _ states: [ReaderCloudReadingState],
        deviceID: UUID,
        accessToken: String
    ) async throws -> [ReaderCloudReadingState] {
        throw ReaderBackendError.invalidConfiguration
    }

    func matchLibraryFile(
        _ publicationID: UUID,
        to result: ReaderCatalogResult,
        source: ReaderCatalogMatchSource,
        accessToken: String
    ) async throws {
        throw ReaderBackendError.invalidConfiguration
    }
}

actor ReaderBackendClient: ReaderBackendServicing {
    private struct CredentialsBody: Encodable {
        let email: String
        let password: String
    }

    private struct RefreshBody: Encodable {
        let refreshToken: String
    }

    private struct SessionEnvelope: Decodable {
        let session: ReaderAuthSession
    }

    private struct SignUpEnvelope: Decodable {
        let session: ReaderAuthSession?
        let user: ReaderAuthUser?
        let requiresEmailConfirmation: Bool
    }

    private struct HighlightAnswerEnvelope: Decodable {
        struct Response: Decodable {
            let text: String
            let model: String
        }

        let response: Response
    }

    private struct AnnotationSyncEnvelope: Codable {
        let annotations: [AnnotationPayload]
    }

    private struct AnnotationPayload: Codable {
        let id: UUID
        let publicationFingerprint: String
        let locator: ReaderLocator
        let selectedText: String
        let note: String?
        let highlightColor: ReaderHighlightColor
        let createdAt: Double
        let updatedAt: Double

        init(annotation: ReaderAnnotation) {
            id = annotation.id
            publicationFingerprint = annotation.publicationFingerprint
            locator = annotation.locator
            selectedText = annotation.selectedText
            note = annotation.note
            highlightColor = annotation.highlightColor
            createdAt = annotation.createdAt.timeIntervalSince1970
            updatedAt = annotation.updatedAt.timeIntervalSince1970
        }

        var annotation: ReaderAnnotation {
            ReaderAnnotation(
                id: id,
                publicationFingerprint: publicationFingerprint,
                locator: locator,
                selectedText: selectedText,
                note: note,
                highlightColor: highlightColor,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    private struct ReadingStateSyncRequest: Encodable {
        struct State: Encodable {
            let fileId: UUID
            let locator: ReaderLocator
            let progress: Double
            let lastOpenedAt: Double
            let updatedAt: Double

            init(_ state: ReaderCloudReadingState) {
                fileId = state.fileID
                locator = state.locator
                progress = state.progress
                lastOpenedAt = state.lastOpenedAt.timeIntervalSince1970
                updatedAt = state.updatedAt.timeIntervalSince1970
            }
        }

        let deviceId: UUID
        let states: [State]
    }

    private struct ReadingStateSyncResponse: Decodable {
        struct State: Decodable {
            let fileId: UUID
            let locator: ReaderLocator
            let progress: Double
            let lastOpenedAt: Double
            let updatedAt: Double

            var readingState: ReaderCloudReadingState {
                ReaderCloudReadingState(
                    fileID: fileId,
                    locator: locator,
                    progress: progress,
                    lastOpenedAt: Date(timeIntervalSince1970: lastOpenedAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
        }

        let readingStates: [State]
    }

    private struct LibraryFoldersEnvelope: Decodable {
        let folders: [ReaderLibraryFolder]
    }

    private struct LibraryFilesEnvelope: Decodable {
        let files: [ReaderLibraryFile]
    }

    private struct LibraryFolderEnvelope: Decodable {
        let folder: ReaderLibraryFolder
    }

    private struct LibraryFileEnvelope: Decodable {
        let file: ReaderLibraryFile
    }

    private struct LibraryFileDownloadEnvelope: Decodable {
        let url: URL
    }

    private struct CreateLibraryBody: Encodable {
        let name: String
        let parentID: UUID?

        enum CodingKeys: String, CodingKey {
            case name
            case parentID = "parentId"
        }
    }

    private struct MoveLibraryFileBody: Encodable {
        let folderID: UUID?

        enum CodingKeys: String, CodingKey {
            case folderID = "folderId"
        }
    }

    private struct RenameLibraryBody: Encodable {
        let name: String
    }

    private struct LibraryFileOrderBody: Encodable {
        let fileIds: [UUID]
    }

    private struct StreamDelta: Decodable {
        let text: String
    }

    private struct StreamCompletion: Decodable {
        let model: String
        let finishReason: String
    }

    private struct StreamEvidence: Decodable {
        let label: String
    }

    private struct StreamFailure: Decodable {
        let code: String
        let message: String
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let code: String
            let message: String
        }

        let error: APIError
    }

    private struct ChatTitleEnvelope: Decodable {
        let response: ReaderChatTitle
    }

    private struct StartKnowledgeBody: Encodable {
        let title: String
        let author: String?
        let format: String
        let fingerprint: String
        let parserVersion: Int
        let totalChunks: Int
        let totalCharacters: Int
        let annotations: [ReaderBookKnowledgeSnapshot.Annotation]
    }

    private struct StartKnowledgeResponse: Decodable {
        let needsChunks: Bool
    }

    private struct KnowledgeChunkBatch: Encodable {
        let fingerprint: String
        let chunks: [ReaderBookKnowledgeSnapshot.Chunk]
    }

    private struct KnowledgeBatchResponse: Decodable {
        let accepted: Int
    }

    private struct CompleteKnowledgeBody: Encodable {
        let fingerprint: String
        let expectedChunks: Int
        let expectedCharacters: Int
    }

    private struct CompleteKnowledgeResponse: Decodable {
        let processingStatus: String
    }

    private struct StartFileUploadBody: Encodable {
        let clientFileId: UUID
        let displayName: String
        let originalFilename: String
        let mediaType: String
        let byteSize: Int
        let sha256: String
    }

    private struct StartFileUploadResponse: Decodable {
        struct SignedUpload: Decodable {
            let signedUrl: URL
        }

        let needsUpload: Bool
        let upload: SignedUpload?
    }

    private struct CompleteFileUploadResponse: Decodable {
        struct File: Decodable {
            let status: String
        }

        let file: File
    }

    private struct CatalogSearchEnvelope: Decodable {
        let results: [ReaderCatalogResult]
    }

    private struct CatalogInterestBody: Encodable {
        let workGroupId: Int64?
        let source: ReaderCatalogSource?
        let externalId: String?
        let title: String?
        let authors: String?
        let primaryIdentifier: String?
        let emailOptIn: Bool
    }

    private struct CatalogInterestEnvelope: Decodable {
        let registered: Bool
    }

    private struct CatalogMatchBody: Encodable {
        let workGroupId: Int64
        let workId: Int64?
        let editionId: Int64?
        let source: ReaderCatalogMatchSource
    }

    private struct CatalogMatchEnvelope: Decodable {
        let matched: Bool
    }

    private struct EmptyBody: Encodable {}

    private let baseURL: URL
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        encoder.dateEncodingStrategy = .iso8601
    }

    static func live() -> ReaderBackendClient {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "ReaderBackendURL"
        ) as? String
        let normalized = configured?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = normalized
            .flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:3000")!
        return ReaderBackendClient(baseURL: url)
    }

    func signIn(email: String, password: String) async throws -> ReaderAuthSession {
        let envelope: SessionEnvelope = try await post(
            path: "v1/auth/sign-in",
            body: CredentialsBody(email: email, password: password)
        )
        return envelope.session
    }

    func signUp(email: String, password: String) async throws -> ReaderSignUpResult {
        let envelope: SignUpEnvelope = try await post(
            path: "v1/auth/sign-up",
            body: CredentialsBody(email: email, password: password)
        )
        return ReaderSignUpResult(
            session: envelope.session,
            user: envelope.user,
            requiresEmailConfirmation: envelope.requiresEmailConfirmation
        )
    }

    func refreshSession(refreshToken: String) async throws -> ReaderAuthSession {
        let envelope: SessionEnvelope = try await post(
            path: "v1/auth/refresh",
            body: RefreshBody(refreshToken: refreshToken)
        )
        return envelope.session
    }

    func answerHighlightQuestion(
        _ request: HighlightQuestionRequest,
        accessToken: String
    ) async throws -> HighlightQuestionAnswer {
        let envelope: HighlightAnswerEnvelope = try await post(
            path: "v1/ai/highlight-question",
            body: request,
            accessToken: accessToken
        )
        return HighlightQuestionAnswer(
            text: envelope.response.text,
            model: envelope.response.model
        )
    }

    func syncAnnotations(
        _ annotations: [ReaderAnnotation],
        accessToken: String
    ) async throws -> [ReaderAnnotation] {
        let envelope: AnnotationSyncEnvelope = try await post(
            path: "v1/annotations/sync",
            body: AnnotationSyncEnvelope(
                annotations: annotations.map(AnnotationPayload.init)
            ),
            accessToken: accessToken
        )
        return envelope.annotations.map(\.annotation)
    }

    func libraryOrganization(
        accessToken: String
    ) async throws -> ReaderLibraryOrganization {
        let folderEnvelope: LibraryFoldersEnvelope = try await get(
            path: "v1/folders",
            accessToken: accessToken
        )
        let fileEnvelope: LibraryFilesEnvelope = try await get(
            path: "v1/files",
            queryItems: [URLQueryItem(name: "all", value: "true")],
            accessToken: accessToken
        )
        return ReaderLibraryOrganization(
            folders: folderEnvelope.folders,
            files: fileEnvelope.files
        )
    }

    func syncReadingStates(
        _ states: [ReaderCloudReadingState],
        deviceID: UUID,
        accessToken: String
    ) async throws -> [ReaderCloudReadingState] {
        let envelope: ReadingStateSyncResponse = try await post(
            path: "v1/reading-states/sync",
            body: ReadingStateSyncRequest(
                deviceId: deviceID,
                states: states.map(ReadingStateSyncRequest.State.init)
            ),
            accessToken: accessToken
        )
        return envelope.readingStates.map(\.readingState)
    }

    func createLibrary(
        name: String,
        parentID: UUID?,
        accessToken: String
    ) async throws -> ReaderLibraryFolder {
        let envelope: LibraryFolderEnvelope = try await send(
            method: "POST",
            path: "v1/folders",
            body: CreateLibraryBody(name: name, parentID: parentID),
            accessToken: accessToken
        )
        return envelope.folder
    }

    func renameLibrary(
        _ libraryID: UUID,
        name: String,
        accessToken: String
    ) async throws -> ReaderLibraryFolder {
        let envelope: LibraryFolderEnvelope = try await send(
            method: "PATCH",
            path: "v1/folders/\(libraryID.uuidString)",
            body: RenameLibraryBody(name: name),
            accessToken: accessToken
        )
        return envelope.folder
    }

    func deleteLibrary(
        _ libraryID: UUID,
        accessToken: String
    ) async throws {
        try await sendWithoutResponse(
            method: "DELETE",
            path: "v1/folders/\(libraryID.uuidString)",
            accessToken: accessToken
        )
    }

    func moveLibraryFile(
        _ fileID: UUID,
        to folderID: UUID?,
        accessToken: String
    ) async throws -> ReaderLibraryFile {
        let envelope: LibraryFileEnvelope = try await send(
            method: "PATCH",
            path: "v1/files/\(fileID.uuidString)",
            body: MoveLibraryFileBody(folderID: folderID),
            accessToken: accessToken
        )
        return envelope.file
    }

    func saveLibraryFileOrder(
        _ fileIDs: [UUID],
        accessToken: String
    ) async throws {
        try await sendWithoutResponse(
            method: "PUT",
            path: "v1/files/order",
            body: LibraryFileOrderBody(fileIds: fileIDs),
            accessToken: accessToken
        )
    }

    func downloadLibraryFile(
        _ fileID: UUID,
        accessToken: String
    ) async throws -> URL {
        let envelope: LibraryFileDownloadEnvelope = try await post(
            path: "v1/files/\(fileID.uuidString)/download",
            body: EmptyBody(),
            accessToken: accessToken
        )

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await urlSession.download(from: envelope.url)
        } catch {
            throw Self.normalizedTransportError(error)
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ReaderBackendError.invalidResponse
        }
        return temporaryURL
    }

    func searchCatalog(
        query: String,
        locale: String,
        limit: Int,
        accessToken: String
    ) async throws -> [ReaderCatalogResult] {
        let envelope: CatalogSearchEnvelope = try await get(
            path: "v1/catalog/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "locale", value: locale),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "includeFallback", value: "true"),
            ],
            accessToken: accessToken
        )
        return envelope.results
    }

    func registerCatalogInterest(
        _ result: ReaderCatalogResult,
        emailOptIn: Bool,
        accessToken: String
    ) async throws {
        let body: CatalogInterestBody
        if let workGroupID = result.workGroupId {
            body = CatalogInterestBody(
                workGroupId: workGroupID,
                source: nil,
                externalId: nil,
                title: nil,
                authors: nil,
                primaryIdentifier: nil,
                emailOptIn: emailOptIn
            )
        } else if
            result.source == .googleBooks,
            let externalID = result.externalId
        {
            body = CatalogInterestBody(
                workGroupId: nil,
                source: .googleBooks,
                externalId: externalID,
                title: result.title,
                authors: result.authors,
                primaryIdentifier: result.primaryIdentifier,
                emailOptIn: emailOptIn
            )
        } else {
            throw ReaderBackendError.invalidResponse
        }
        let envelope: CatalogInterestEnvelope = try await post(
            path: "v1/catalog/interests",
            body: body,
            accessToken: accessToken
        )
        guard envelope.registered else {
            throw ReaderBackendError.invalidResponse
        }
    }

    func matchLibraryFile(
        _ publicationID: UUID,
        to result: ReaderCatalogResult,
        source: ReaderCatalogMatchSource,
        accessToken: String
    ) async throws {
        guard let workGroupID = result.workGroupId else {
            throw ReaderBackendError.invalidResponse
        }
        let envelope: CatalogMatchEnvelope = try await send(
            method: "PUT",
            path: "v1/files/\(publicationID.uuidString)/catalog-match",
            body: CatalogMatchBody(
                workGroupId: workGroupID,
                workId: result.workId,
                editionId: result.editionId,
                source: source
            ),
            accessToken: accessToken
        )
        guard envelope.matched else {
            throw ReaderBackendError.invalidResponse
        }
    }

    private func libraryFiles(
        in folderID: UUID?,
        accessToken: String
    ) async throws -> [ReaderLibraryFile] {
        let queryItems = folderID.map {
            [URLQueryItem(name: "folderId", value: $0.uuidString)]
        } ?? []
        let envelope: LibraryFilesEnvelope = try await get(
            path: "v1/files",
            queryItems: queryItems,
            accessToken: accessToken
        )
        return envelope.files
    }

    func streamChat(
        _ request: ReaderChatRequest,
        accessToken: String
    ) async throws -> AsyncThrowingStream<ReaderChatStreamEvent, Error> {
        guard let url = URL(
            string: "v1/ai/chat/stream",
            relativeTo: baseURL
        )?.absoluteURL else {
            throw ReaderBackendError.invalidConfiguration
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "authorization"
        )
        urlRequest.httpBody = try encoder.encode(request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: urlRequest)
        } catch {
            throw Self.normalizedTransportError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderBackendError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw ReaderBackendError.server(
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw Self.error(forHTTPStatus: httpResponse.statusCode)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let streamDecoder = JSONDecoder()
                var eventName: String?
                var completed = false

                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6))
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }

                        let payload = String(line.dropFirst(5))
                            .trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8) else {
                            throw ReaderBackendError.invalidResponse
                        }

                        switch eventName {
                        case "delta":
                            let delta = try streamDecoder.decode(
                                StreamDelta.self,
                                from: data
                            )
                            continuation.yield(.delta(delta.text))
                        case "complete":
                            let completion = try streamDecoder.decode(
                                StreamCompletion.self,
                                from: data
                            )
                            completed = true
                            continuation.yield(
                                .complete(
                                    model: completion.model,
                                    finishReason: completion.finishReason
                                )
                            )
                        case "evidence":
                            let evidence = try streamDecoder.decode(
                                StreamEvidence.self,
                                from: data
                            )
                            continuation.yield(.evidence(evidence.label))
                        case "error":
                            let failure = try streamDecoder.decode(
                                StreamFailure.self,
                                from: data
                            )
                            throw ReaderBackendError.server(
                                code: failure.code,
                                message: failure.message
                            )
                        default:
                            break
                        }
                        eventName = nil
                    }

                    if !completed {
                        throw ReaderBackendError.invalidResponse
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generateChatTitle(
        _ request: ReaderChatTitleRequest,
        accessToken: String
    ) async throws -> ReaderChatTitle {
        let envelope: ChatTitleEnvelope = try await post(
            path: "v1/ai/chat/title",
            body: request,
            accessToken: accessToken
        )
        return envelope.response
    }

    func ingestBookKnowledge(
        _ request: ReaderBookKnowledgeIngestionRequest,
        accessToken: String
    ) async throws {
        let start: StartKnowledgeResponse = try await send(
            method: "POST",
            path: "v1/publications/\(request.publicationID.uuidString)/ingestions",
            body: StartKnowledgeBody(
                title: request.title,
                author: request.author.isEmpty ? nil : request.author,
                format: request.format.rawValue,
                fingerprint: request.fingerprint,
                parserVersion: 1,
                totalChunks: request.chunks.count,
                totalCharacters: request.chunks.reduce(0) { $0 + $1.text.count },
                annotations: request.annotations
            ),
            accessToken: accessToken
        )
        guard start.needsChunks else { return }

        let batches = request.chunks.chunked(maximumCount: 100, maximumCharacters: 900_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = batches.makeIterator()
            for _ in 0..<min(4, batches.count) {
                guard let batch = iterator.next() else { break }
                group.addTask { [self] in
                    let _: KnowledgeBatchResponse = try await send(
                        method: "PUT",
                        path: "v1/publications/\(request.publicationID.uuidString)/chunks",
                        body: KnowledgeChunkBatch(
                            fingerprint: request.fingerprint,
                            chunks: batch
                        ),
                        accessToken: accessToken
                    )
                }
            }
            while try await group.next() != nil {
                if let batch = iterator.next() {
                    group.addTask { [self] in
                        let _: KnowledgeBatchResponse = try await send(
                            method: "PUT",
                            path: "v1/publications/\(request.publicationID.uuidString)/chunks",
                            body: KnowledgeChunkBatch(
                                fingerprint: request.fingerprint,
                                chunks: batch
                            ),
                            accessToken: accessToken
                        )
                    }
                }
            }
        }

        let completion: CompleteKnowledgeResponse = try await send(
            method: "POST",
            path: "v1/publications/\(request.publicationID.uuidString)/complete",
            body: CompleteKnowledgeBody(
                fingerprint: request.fingerprint,
                expectedChunks: request.chunks.count,
                expectedCharacters: request.chunks.reduce(0) { $0 + $1.text.count }
            ),
            accessToken: accessToken
        )
        guard completion.processingStatus == "parsed" else {
            throw ReaderBackendError.invalidResponse
        }
    }

    func syncLibraryFile(
        _ upload: ReaderLibraryFileUpload,
        accessToken: String
    ) async throws {
        let start: StartFileUploadResponse = try await send(
            method: "POST",
            path: "v1/files/uploads",
            body: StartFileUploadBody(
                clientFileId: upload.publicationID,
                displayName: upload.displayName,
                originalFilename: upload.sourceURL.lastPathComponent,
                mediaType: upload.mediaType,
                byteSize: upload.byteSize,
                sha256: upload.sha256
            ),
            accessToken: accessToken
        )
        guard start.needsUpload else { return }
        guard let signedUpload = start.upload else {
            throw ReaderBackendError.invalidResponse
        }

        var request = URLRequest(url: signedUpload.signedUrl)
        request.httpMethod = "PUT"
        request.setValue(upload.mediaType, forHTTPHeaderField: "content-type")
        request.setValue("3600", forHTTPHeaderField: "cache-control")
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        let response: URLResponse
        do {
            (_, response) = try await urlSession.upload(
                for: request,
                fromFile: upload.sourceURL
            )
        } catch {
            throw Self.normalizedTransportError(error)
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw ReaderBackendError.invalidResponse
        }

        let completion: CompleteFileUploadResponse = try await send(
            method: "POST",
            path: "v1/files/\(upload.publicationID.uuidString)/complete",
            body: EmptyBody(),
            accessToken: accessToken
        )
        guard completion.file.status == "ready" else {
            throw ReaderBackendError.invalidResponse
        }
    }

    private func post<ResponseBody: Decodable, RequestBody: Encodable>(
        path: String,
        body: RequestBody,
        accessToken: String? = nil
    ) async throws -> ResponseBody {
        try await send(
            method: "POST",
            path: path,
            body: body,
            accessToken: accessToken
        )
    }

    private func get<ResponseBody: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        accessToken: String
    ) async throws -> ResponseBody {
        let request = try makeRequest(
            method: "GET",
            path: path,
            queryItems: queryItems,
            accessToken: accessToken
        )
        return try await response(for: request)
    }

    private func send<ResponseBody: Decodable, RequestBody: Encodable>(
        method: String,
        path: String,
        body: RequestBody,
        accessToken: String? = nil
    ) async throws -> ResponseBody {
        var request = try makeRequest(
            method: method,
            path: path,
            accessToken: accessToken
        )
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(body)
        return try await response(for: request)
    }

    private func sendWithoutResponse<RequestBody: Encodable>(
        method: String,
        path: String,
        body: RequestBody,
        accessToken: String
    ) async throws {
        var request = try makeRequest(
            method: method,
            path: path,
            accessToken: accessToken
        )
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try encoder.encode(body)
        try await responseWithoutBody(for: request)
    }

    private func sendWithoutResponse(
        method: String,
        path: String,
        accessToken: String
    ) async throws {
        let request = try makeRequest(
            method: method,
            path: path,
            accessToken: accessToken
        )
        try await responseWithoutBody(for: request)
    }

    private func responseWithoutBody(for request: URLRequest) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.normalizedTransportError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderBackendError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw ReaderBackendError.server(
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw Self.error(forHTTPStatus: httpResponse.statusCode)
        }
    }

    private func makeRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        accessToken: String?
    ) throws -> URLRequest {
        guard
            let relativeURL = URL(string: path, relativeTo: baseURL)?.absoluteURL,
            var components = URLComponents(url: relativeURL, resolvingAgainstBaseURL: true)
        else {
            throw ReaderBackendError.invalidConfiguration
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ReaderBackendError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accessToken {
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "authorization"
            )
        }
        return request
    }

    private func response<ResponseBody: Decodable>(
        for request: URLRequest
    ) async throws -> ResponseBody {

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.normalizedTransportError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderBackendError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw ReaderBackendError.server(
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw Self.error(forHTTPStatus: httpResponse.statusCode)
        }

        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw ReaderBackendError.invalidResponse
        }
    }

    static func normalizedTransportError(_ error: Error) -> ReaderBackendError {
        guard let urlError = error as? URLError else {
            return .invalidResponse
        }

        switch urlError.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnectionFailed
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return .networkUnavailable
        default:
            return .invalidResponse
        }
    }

    static func error(forHTTPStatus statusCode: Int) -> ReaderBackendError {
        switch statusCode {
        case 404:
            .endpointUnavailable
        case 502...504:
            .serviceUnavailable
        default:
            .invalidResponse
        }
    }
}
