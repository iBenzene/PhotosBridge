//
//  SnapshotPagination.swift
//  PhotosBridge
//
//  Created by 埃苯泽 on 29/7/2026.
//

import Foundation

struct SnapshotPageBounds: Equatable, Sendable {
    let range: Range<Int>
    let nextCursor: String?

    static func calculate(totalCount: Int, cursor: String?, requestedLimit: Int) throws -> SnapshotPageBounds {
        guard totalCount >= 0 else { throw PhotoLibraryFailure.snapshotInvalidated }
        let offset = cursor.flatMap(Int.init) ?? 0
        guard offset >= 0, offset <= totalCount else { throw PhotoLibraryFailure.snapshotInvalidated }
        let limit = min(max(requestedLimit, 1), 500)
        let end = min(offset + limit, totalCount)
        return SnapshotPageBounds(range: offset..<end, nextCursor: end < totalCount ? String(end) : nil)
    }
}
