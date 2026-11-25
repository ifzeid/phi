import Foundation

/// Pure rules for album delete: locals stay until Photos confirms, then records that
/// share a `photosIdentifier` are cleared too, including ones not selected as `.local`.
enum AlbumDeleteSync {
    static func shouldClearLocalRecords(photosConfirmed: Bool, cancelled: Bool) -> Bool {
        photosConfirmed && cancelled == false
    }

    static func localIDs(
        matching photosIdentifiers: [String],
        records: [(id: String, photosIdentifier: String?)]
    ) -> [String] {
        let dropping = Set(photosIdentifiers.filter { $0.isEmpty == false })
        guard dropping.isEmpty == false else { return [] }
        return records.compactMap { record in
            guard let identifier = record.photosIdentifier, dropping.contains(identifier) else { return nil }
            return record.id
        }
    }
}
