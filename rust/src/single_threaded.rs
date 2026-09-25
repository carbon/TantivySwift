//! A tantivy writer that does all of its work on the calling thread.
//!
//! tantivy's `IndexWriter` indexes on worker threads, merges on a thread pool,
//! and compresses the doc store on a thread of its own. WebAssembly without
//! threads can start none of them, so the `single-threaded` feature swaps in
//! this writer, built from the public pieces `IndexWriter` is made of:
//!
//!  * documents go straight into a `SegmentWriter`, which is flushed to an
//!    uncommitted segment whenever it outgrows the memory budget;
//!  * deletes are queued with their opstamp and applied at commit, each to the
//!    documents added before it — tantivy's ordering, without its delete queue;
//!  * a commit writes the delete files and `meta.json` itself;
//!  * merges run in line after each commit (tantivy's `LogMergePolicy`), or on
//!    request, through `merge_filtered_segments`.
//!
//! Opstamps are handed out exactly as `IndexWriter` hands them out, so callers
//! see the same values from `commit` and `rollback` whichever writer is built.
//!
//! The index must have `docstore_compress_dedicated_thread` off (see
//! `single_threaded::settings`), or finalizing a segment would try to start the
//! doc-store compressor thread.

use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};

use tantivy::directory::{Directory, DirectoryLock, RamDirectory, TerminatingWrite, INDEX_WRITER_LOCK};
use tantivy::fastfield::write_alive_bitset;
use tantivy::index::{SegmentComponent, SegmentReader};
use tantivy::indexer::{merge_filtered_segments, AddOperation, LogMergePolicy, MergePolicy, SegmentWriter};
use tantivy::query::{EnableScoring, Query, TermQuery, Weight};
use tantivy::schema::{IndexRecordOption, TantivyDocument, Term};
use tantivy::{
    DocId, Index, IndexMeta, IndexReader, IndexSettings, Opstamp, Segment, SegmentMeta,
    TantivyError,
};
use tantivy_common::BitSet;

// tantivy's own bounds for a writer's memory budget (`index_writer.rs`, not
// exported). A segment is flushed once its arena comes within `MARGIN` of the
// budget.
const MARGIN_IN_BYTES: usize = 1_000_000;
const MEMORY_BUDGET_MIN: usize = MARGIN_IN_BYTES * 15;
const MEMORY_BUDGET_MAX: usize = u32::MAX as usize - MARGIN_IN_BYTES;

/// Index settings for an index this writer will write to: the defaults, with
/// the doc store compressed in line rather than on a dedicated thread.
pub fn settings() -> IndexSettings {
    IndexSettings {
        docstore_compress_dedicated_thread: false,
        ..IndexSettings::default()
    }
}

/// A flushed, not yet committed segment, with the opstamp of each document in
/// it so a later delete only touches documents added before it.
struct PendingSegment {
    meta: SegmentMeta,
    doc_opstamps: Vec<Opstamp>,
}

/// A queued delete: the documents `weight` matches, among those added before
/// `opstamp`.
struct DeleteOperation {
    opstamp: Opstamp,
    weight: Box<dyn Weight>,
}

pub struct SingleThreadedWriter {
    index: Index,
    /// Held for the writer's lifetime, as `IndexWriter` holds it, so a second
    /// writer on the same index fails the same way.
    _lock: DirectoryLock,
    memory_budget: usize,
    /// Reloaded after every change to `meta.json` when set — the in-line
    /// counterpart of `ReloadPolicy::OnCommitWithDelay`, whose watcher needs a
    /// thread.
    reader: Option<IndexReader>,

    /// The segments of the last commit.
    committed: Vec<SegmentMeta>,
    committed_opstamp: Opstamp,
    /// The next opstamp to hand out.
    next_opstamp: Opstamp,

    /// Everything below is queued for the next commit.
    current: Option<(Segment, SegmentWriter)>,
    pending: Vec<PendingSegment>,
    deletes: Vec<DeleteOperation>,
    /// `delete_all_documents` drops the committed segments at the next commit.
    drop_committed: bool,
}

impl SingleThreadedWriter {
    pub fn new(
        index: &Index,
        memory_budget: usize,
        reader: Option<IndexReader>,
    ) -> tantivy::Result<Self> {
        let lock = index.directory().acquire_lock(&INDEX_WRITER_LOCK).map_err(|err| {
            TantivyError::LockFailure(
                err,
                Some(
                    "Failed to acquire index lock. If you are using a regular directory, this \
                     means there is already an `IndexWriter` working on this `Directory`, in \
                     this process or in a different process."
                        .to_string(),
                ),
            )
        })?;
        if memory_budget < MEMORY_BUDGET_MIN {
            return Err(TantivyError::InvalidArgument(format!(
                "The memory arena in bytes per thread needs to be at least {MEMORY_BUDGET_MIN}."
            )));
        }
        if memory_budget >= MEMORY_BUDGET_MAX {
            return Err(TantivyError::InvalidArgument(format!(
                "The memory arena in bytes per thread cannot exceed {MEMORY_BUDGET_MAX}"
            )));
        }
        let meta = index.load_metas()?;
        Ok(SingleThreadedWriter {
            index: index.clone(),
            _lock: lock,
            memory_budget,
            reader,
            committed: meta.segments,
            committed_opstamp: meta.opstamp,
            next_opstamp: meta.opstamp,
            current: None,
            pending: Vec::new(),
            deletes: Vec::new(),
            drop_committed: false,
        })
    }

    pub fn index(&self) -> &Index {
        &self.index
    }

    fn stamp(&mut self) -> Opstamp {
        let opstamp = self.next_opstamp;
        self.next_opstamp += 1;
        opstamp
    }

    // -- Adding ---------------------------------------------------------------

    pub fn add_document(&mut self, document: TantivyDocument) -> tantivy::Result<Opstamp> {
        let opstamp = self.stamp();
        if self.current.is_none() {
            let segment = self.index.new_segment();
            let writer = SegmentWriter::for_segment(self.memory_budget, segment.clone())?;
            self.current = Some((segment, writer));
        }
        let (_, writer) = self.current.as_mut().expect("created above");
        writer.add_document(AddOperation { opstamp, document })?;
        if writer.mem_usage() >= self.memory_budget - MARGIN_IN_BYTES {
            self.flush_current()?;
        }
        Ok(opstamp)
    }

    /// Finalize the in-memory segment into an uncommitted one.
    fn flush_current(&mut self) -> tantivy::Result<()> {
        if let Some((segment, writer)) = self.current.take() {
            let max_doc = writer.max_doc();
            let doc_opstamps = writer.finalize()?;
            if max_doc > 0 {
                self.pending.push(PendingSegment {
                    meta: segment.with_max_doc(max_doc).meta().clone(),
                    doc_opstamps,
                });
            }
        }
        Ok(())
    }

    // -- Deleting -------------------------------------------------------------

    pub fn delete_term(&mut self, term: Term) -> Opstamp {
        let query = TermQuery::new(term, IndexRecordOption::Basic);
        // As `IndexWriter::delete_term`: a term the schema cannot build a
        // weight for deletes nothing, but still takes an opstamp.
        self.delete_query(Box::new(query))
            .unwrap_or_else(|_| self.stamp())
    }

    pub fn delete_query(&mut self, query: Box<dyn Query>) -> tantivy::Result<Opstamp> {
        // Built now, as `IndexWriter` builds it, so a query that cannot run
        // unscored fails at the call rather than at commit.
        let weight = query.weight(EnableScoring::disabled_from_schema(&self.index.schema()))?;
        let opstamp = self.stamp();
        self.deletes.push(DeleteOperation { opstamp, weight });
        Ok(opstamp)
    }

    /// Drop every document added so far, committed or not. Documents added
    /// afterwards are kept.
    pub fn delete_all_documents(&mut self) -> tantivy::Result<Opstamp> {
        self.current = None;
        self.pending.clear();
        self.deletes.clear();
        self.drop_committed = true;
        // `IndexWriter` reverts its stamper here too.
        self.next_opstamp = self.committed_opstamp;
        Ok(self.committed_opstamp)
    }

    // -- Committing -----------------------------------------------------------

    pub fn commit(&mut self) -> tantivy::Result<Opstamp> {
        let opstamp = self.stamp();
        self.flush_current()?;

        let committed = if self.drop_committed {
            Vec::new()
        } else {
            std::mem::take(&mut self.committed)
        };
        let pending = std::mem::take(&mut self.pending);
        let deletes = std::mem::take(&mut self.deletes);

        let mut segments = Vec::with_capacity(committed.len() + pending.len());
        // Every committed document predates every queued delete.
        for meta in committed {
            segments.extend(self.apply_deletes(meta, None, &deletes, opstamp)?);
        }
        for p in pending {
            segments.extend(self.apply_deletes(p.meta, Some(&p.doc_opstamps), &deletes, opstamp)?);
        }

        self.committed = segments;
        self.committed_opstamp = opstamp;
        self.drop_committed = false;
        self.save_metas()?;
        self.merge_by_policy()?;
        self.garbage_collect_files()?;
        self.reload()?;
        Ok(opstamp)
    }

    /// Apply `deletes` to a segment, writing a new delete file if any document
    /// is newly deleted. `doc_opstamps` is `None` for a committed segment, all
    /// of whose documents predate the deletes. Returns `None` once nothing in
    /// the segment is alive, so it drops out of the index.
    fn apply_deletes(
        &self,
        meta: SegmentMeta,
        doc_opstamps: Option<&[Opstamp]>,
        deletes: &[DeleteOperation],
        opstamp: Opstamp,
    ) -> tantivy::Result<Option<SegmentMeta>> {
        if deletes.is_empty() {
            return Ok(Some(meta));
        }
        let segment = self.index.segment(meta.clone());
        let reader = SegmentReader::open(&segment)?;
        let max_doc = reader.max_doc();

        let mut alive = BitSet::with_max_value_and_full(max_doc);
        if let Some(existing) = reader.alive_bitset() {
            for doc in 0..max_doc {
                if !existing.is_alive(doc) {
                    alive.remove(doc);
                }
            }
        }
        let alive_before = alive.len();

        for delete in deletes {
            delete.weight.for_each_no_score(&reader, &mut |docs: &[DocId]| {
                for &doc in docs {
                    let added_before = doc_opstamps
                        .is_none_or(|stamps| stamps[doc as usize] < delete.opstamp);
                    if added_before {
                        alive.remove(doc);
                    }
                }
            })?;
        }

        if alive.len() == alive_before {
            return Ok(Some(meta));
        }
        if alive.len() == 0 {
            return Ok(None);
        }
        let mut segment = segment.with_delete_meta(max_doc - alive.len() as u32, opstamp);
        let mut file = segment.open_write(SegmentComponent::Delete)?;
        write_alive_bitset(&alive, &mut file)?;
        file.terminate()?;
        Ok(Some(segment.meta().clone()))
    }

    /// Discard everything queued since the last commit.
    pub fn rollback(&mut self) -> tantivy::Result<Opstamp> {
        self.discard_uncommitted();
        self.next_opstamp = self.committed_opstamp;
        self.garbage_collect_files()?;
        Ok(self.committed_opstamp)
    }

    fn discard_uncommitted(&mut self) {
        self.current = None;
        self.pending.clear();
        self.deletes.clear();
        self.drop_committed = false;
    }

    /// Write the committed state to `meta.json`, as tantivy's `save_metas`.
    fn save_metas(&self) -> tantivy::Result<()> {
        let meta = IndexMeta {
            index_settings: self.index.settings().clone(),
            segments: self.committed.clone(),
            schema: self.index.schema(),
            opstamp: self.committed_opstamp,
            payload: None,
        };
        let mut buffer = serde_json::to_vec_pretty(&meta)?;
        // Just like tantivy, which ends the file with a newline.
        writeln!(&mut buffer)?;
        let directory = self.index.directory();
        directory.atomic_write(Path::new("meta.json"), &buffer[..])?;
        directory.sync_directory()?;
        Ok(())
    }

    fn reload(&self) -> tantivy::Result<()> {
        match &self.reader {
            Some(reader) => reader.reload(),
            None => Ok(()),
        }
    }

    // -- Merging --------------------------------------------------------------

    /// Merge every committed segment into one — when there are several, or a
    /// single one still holding deleted documents.
    pub fn merge_all(&mut self) -> tantivy::Result<()> {
        let has_deletes = self.committed.iter().any(|s| s.num_deleted_docs() > 0);
        if self.committed.len() < 2 && !has_deletes {
            return Ok(());
        }
        let ids: Vec<_> = self.committed.iter().map(|s| s.id()).collect();
        self.merge(&ids)?;
        self.save_metas()?;
        self.garbage_collect_files()?;
        self.reload()
    }

    /// Merge what tantivy's default policy picks, until it picks nothing.
    fn merge_by_policy(&mut self) -> tantivy::Result<()> {
        let policy = LogMergePolicy::default();
        loop {
            let candidates = policy.compute_merge_candidates(&self.committed);
            if candidates.is_empty() {
                return Ok(());
            }
            for candidate in candidates {
                self.merge(&candidate.0)?;
            }
            self.save_metas()?;
        }
    }

    /// Replace the committed segments `ids` with one merged segment, dropping
    /// their deleted documents. Does not write `meta.json`.
    ///
    /// `merge_filtered_segments` writes into an index of its own, so the merge
    /// runs into a scratch in-memory directory and the result is copied over.
    fn merge(&mut self, ids: &[tantivy::index::SegmentId]) -> tantivy::Result<()> {
        let segments: Vec<Segment> = self
            .committed
            .iter()
            .filter(|meta| ids.contains(&meta.id()))
            .map(|meta| self.index.segment(meta.clone()))
            .collect();
        if segments.is_empty() {
            return Ok(());
        }
        let merged = merge_filtered_segments(
            &segments,
            self.index.settings().clone(),
            vec![None; segments.len()],
            RamDirectory::create(),
        )?;
        let merged_meta = merged
            .searchable_segment_metas()?
            .into_iter()
            .next()
            .ok_or_else(|| TantivyError::InternalError("merge produced no segment".into()))?;

        let merged_into_index = if merged_meta.max_doc() > 0 {
            // `list_files` names every component a segment can have, including
            // ones this segment lacks (it has no delete file, for one).
            for path in merged_meta.list_files() {
                if !merged.directory().exists(&path)? {
                    continue;
                }
                let bytes = merged.directory().open_read(&path)?.read_bytes()?;
                let mut file = self.index.directory().open_write(&path)?;
                file.write_all(bytes.as_slice())?;
                file.terminate()?;
            }
            Some(self.index.new_segment_meta(merged_meta.id(), merged_meta.max_doc()))
        } else {
            None
        };

        self.committed.retain(|meta| !ids.contains(&meta.id()));
        self.committed.extend(merged_into_index);
        Ok(())
    }

    // -- Housekeeping ---------------------------------------------------------

    /// Delete every file no segment in use refers to — merged-away segments,
    /// superseded delete files, and rolled-back segments. In memory this is
    /// what gives their bytes back; searchers still holding a deleted file
    /// keep their own reference to its bytes.
    pub fn garbage_collect_files(&mut self) -> tantivy::Result<()> {
        let mut living: HashSet<PathBuf> = HashSet::from([PathBuf::from("meta.json")]);
        for meta in &self.committed {
            living.extend(meta.list_files());
        }
        for pending in &self.pending {
            living.extend(pending.meta.list_files());
        }
        if let Some((segment, _)) = &self.current {
            living.extend(segment.meta().list_files());
        }
        self.index.directory_mut().garbage_collect(|| living)?;
        Ok(())
    }
}

impl Drop for SingleThreadedWriter {
    /// Uncommitted segments are discarded, as they are with `IndexWriter`, and
    /// their files freed while the writer lock is still held.
    fn drop(&mut self) {
        self.discard_uncommitted();
        let _ = self.garbage_collect_files();
    }
}
