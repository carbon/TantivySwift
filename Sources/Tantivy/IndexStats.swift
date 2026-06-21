import Foundation
import CTantivy

/// A snapshot of an index's physical state — document counts and the segment
/// layout — as of the reader's last reload. Use it to decide when to compact:
/// a large ``deletedCount`` (space held by deleted/updated docs that is only
/// reclaimed on merge) or a high ``segmentCount`` (search cost grows with the
/// number of segments) is the signal to call ``Index/optimize()``.
public struct IndexStats: Sendable, Equatable {
    /// Live, searchable documents across all segments.
    public let documentCount: Int
    /// Documents marked deleted but not yet physically removed. These still
    /// occupy disk until a merge; `upsert`/delete-then-add leaves them behind.
    public let deletedCount: Int
    /// Total addressable documents (`documentCount + deletedCount`).
    public let maxDoc: Int
    /// Number of segments. Many small segments slow searches — merge to compact.
    public let segmentCount: Int
    /// Per-segment breakdown, in the reader's segment order.
    public let segments: [Segment]

    /// One segment's counts.
    public struct Segment: Sendable, Equatable {
        /// The segment's UUID string (stable until it is merged away).
        public let id: String
        /// Live documents in this segment.
        public let documentCount: Int
        /// Deleted-but-not-merged documents in this segment.
        public let deletedCount: Int
        /// Total addressable documents in this segment.
        public let maxDoc: Int
    }
}

extension IndexStats: Decodable {
    private enum CodingKeys: String, CodingKey {
        case documentCount = "num_docs"
        case deletedCount = "num_deleted"
        case maxDoc = "max_doc"
        case segmentCount = "num_segments"
        case segments
    }
}

extension IndexStats.Segment: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case documentCount = "num_docs"
        case deletedCount = "num_deleted"
        case maxDoc = "max_doc"
    }
}

extension Index {
    /// The index's current physical statistics — document counts and segment
    /// layout — reflecting the reader's view as of the last ``reload()``.
    ///
    /// ```swift
    /// let s = try index.stats()
    /// if s.deletedCount > s.documentCount / 2 || s.segmentCount > 16 {
    ///     try index.optimize()   // worth compacting
    /// }
    /// ```
    public func stats() throws(TantivyError) -> IndexStats {
        var err: UnsafeMutablePointer<CChar>?
        guard let raw = tantivy_index_stats(handle, &err) else {
            throw TantivyError.take(&err, fallback: "stats failed")
        }
        defer { tantivy_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        do {
            return try JSONDecoder().decode(IndexStats.self, from: data)
        } catch {
            throw TantivyError.encoding("could not decode index stats: \(error)")
        }
    }

    /// Compact the index: merge all segments into one, then reload so searches
    /// see the compacted view. Reclaims space held by deleted documents and
    /// reduces per-search overhead on a fragmented index.
    ///
    /// This opens a writer, so it needs the single-writer lock — do not call it
    /// while another ``IndexWriter`` is open. It blocks until the merge finishes,
    /// which is I/O- and CPU-heavy on a large index; run it off the hot path
    /// (idle time, maintenance windows), guided by ``stats()``.
    public func optimize(heapSize: Int = 0) throws(TantivyError) {
        let writer = try self.writer(heapSize: heapSize)
        try writer.merge()
        try reload()
    }

    /// Reclaim disk by deleting segment files the index no longer references.
    /// ``optimize()`` and commits do this automatically; call it to reclaim
    /// eagerly. Opens a writer, so it needs the single-writer lock.
    public func garbageCollect(heapSize: Int = 0) throws(TantivyError) {
        let writer = try self.writer(heapSize: heapSize)
        try writer.garbageCollect()
    }
}
