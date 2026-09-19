import Foundation

struct ReaderLibraryFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let parentID: UUID?
    let name: String
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ReaderLibraryFile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var folderID: UUID?
    let displayName: String
    let originalFilename: String
    let mediaType: String
    let byteSize: Int64
    let sha256: String?
    let status: String
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case folderID = "folder_id"
        case displayName = "display_name"
        case originalFilename = "original_filename"
        case mediaType = "media_type"
        case byteSize = "byte_size"
        case sha256
        case status
        case sortOrder = "sort_order"
    }

    init(
        id: UUID,
        folderID: UUID?,
        displayName: String,
        originalFilename: String,
        mediaType: String,
        byteSize: Int64,
        sha256: String?,
        status: String,
        sortOrder: Int? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.mediaType = mediaType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.status = status
        self.sortOrder = sortOrder
    }
}

struct ReaderLibraryOrganization: Equatable, Sendable {
    let folders: [ReaderLibraryFolder]
    let files: [ReaderLibraryFile]

    static let empty = ReaderLibraryOrganization(folders: [], files: [])
}

struct ReaderLibraryOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
}

extension Array where Element == ReaderLibraryFolder {
    var libraryOptions: [ReaderLibraryOption] {
        map { folder in
            ReaderLibraryOption(
                id: folder.id,
                title: breadcrumb(for: folder)
            )
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func breadcrumb(for folder: ReaderLibraryFolder) -> String {
        let foldersByID = Dictionary(uniqueKeysWithValues: map { ($0.id, $0) })
        var names = [folder.name]
        var parentID = folder.parentID
        var visited = Set([folder.id])

        while
            let currentID = parentID,
            !visited.contains(currentID),
            let parent = foldersByID[currentID]
        {
            visited.insert(currentID)
            names.insert(parent.name, at: 0)
            parentID = parent.parentID
        }
        return names.joined(separator: " / ")
    }
}
