//! Phrase queries with alternatives at a position — Lucene's `MultiPhraseQuery`.

use tantivy::query::{
    BoostWeight, Bm25StatisticsProvider, DisjunctionMaxQuery, EnableScoring, Query,
    RegexPhraseQuery, TermQuery, Weight,
};
use tantivy::schema::{Field, IndexRecordOption, Term};
use tantivy::Score;

/// A phrase whose positions each accept any of several terms:
/// `[(0, [graphic]), (1, [designers, design])]` matches "graphic designers" and
/// "graphic design". A `PhraseQuery` with two terms at one offset requires
/// both; here one alternative is enough.
///
/// Matching is tantivy's `RegexPhraseQuery` with each position an alternation
/// of escaped literals, which unions the alternatives' postings per position.
///
/// Scoring: `RegexPhraseQuery` takes each position's idf from its *pattern*, as
/// if the pattern were a term. An alternation is never an indexed term, so it
/// gets the idf of an absent term — the maximum. Ranking within the query is
/// unaffected, but the score is inflated against other clauses. The weight is
/// rescaled so each position counts as one term with the idf of its most
/// frequent alternative (how Lucene's `SynonymQuery` scores its pseudo-term):
/// adding a synonym never raises a score, and a phrase with one alternative
/// per position scores exactly as a `PhraseQuery`.
#[derive(Clone, Debug)]
pub struct MultiPhraseQuery {
    field: Field,
    /// Sorted by offset, one entry per offset.
    positions: Vec<Position>,
    slop: u32,
}

#[derive(Clone, Debug)]
struct Position {
    offset: usize,
    /// Deduplicated, in first-seen order; `terms[i]` is `words[i]` as a `Term`.
    words: Vec<String>,
    terms: Vec<Term>,
}

impl MultiPhraseQuery {
    /// `positions` are `(offset, alternatives)`. Entries sharing an offset are
    /// merged into one set of alternatives.
    pub fn new(
        field: Field,
        positions: Vec<(usize, Vec<String>)>,
        slop: u32,
    ) -> Result<MultiPhraseQuery, String> {
        if positions.is_empty() {
            return Err("multi_phrase requires at least one position".to_string());
        }
        let mut merged: Vec<Position> = Vec::with_capacity(positions.len());
        for (offset, words) in positions {
            if words.is_empty() {
                return Err(format!("multi_phrase position at offset {offset} has no terms"));
            }
            let index = match merged.iter().position(|p| p.offset == offset) {
                Some(i) => i,
                None => {
                    merged.push(Position { offset, words: Vec::new(), terms: Vec::new() });
                    merged.len() - 1
                }
            };
            let position = &mut merged[index];
            for word in words {
                if !position.words.contains(&word) {
                    position.terms.push(Term::from_field_text(field, &word));
                    position.words.push(word);
                }
            }
        }
        merged.sort_by_key(|p| p.offset);
        Ok(MultiPhraseQuery { field, positions: merged, slop })
    }

    /// `designers|design`, each alternative escaped so it matches literally.
    fn pattern(position: &Position) -> String {
        position
            .words
            .iter()
            .map(|w| regex_syntax::escape(w))
            .collect::<Vec<_>>()
            .join("|")
    }

    /// The factor that turns `RegexPhraseQuery`'s idf (from the patterns) into
    /// the idf this query means (each position's most frequent alternative).
    fn idf_rescale(
        &self,
        statistics: &dyn Bm25StatisticsProvider,
        patterns: &[(usize, String)],
    ) -> tantivy::Result<Score> {
        let num_docs = statistics.total_num_docs()?;
        let mut applied: Score = 0.0;
        for (_, pattern) in patterns {
            applied += idf(statistics.doc_freq(&Term::from_field_text(self.field, pattern))?, num_docs);
        }
        let mut intended: Score = 0.0;
        for position in &self.positions {
            let mut max_doc_freq = 0;
            for term in &position.terms {
                max_doc_freq = max_doc_freq.max(statistics.doc_freq(term)?);
            }
            intended += idf(max_doc_freq, num_docs);
        }
        // `applied` is a sum of strictly positive idfs, never zero.
        Ok(intended / applied)
    }
}

/// tantivy's BM25 idf (`bm25::idf` is crate-private).
fn idf(doc_freq: u64, num_docs: u64) -> Score {
    let x = (num_docs.saturating_sub(doc_freq) as Score + 0.5) / (doc_freq as Score + 0.5);
    (1.0 + x).ln()
}

impl Query for MultiPhraseQuery {
    fn weight(&self, enable_scoring: EnableScoring<'_>) -> tantivy::Result<Box<dyn Weight>> {
        // `RegexPhraseQuery` asserts on a single position: any one of the
        // alternatives, scored by the best of them so synonyms don't add up.
        if let [position] = self.positions.as_slice() {
            let disjuncts: Vec<Box<dyn Query>> = position
                .terms
                .iter()
                .map(|t| Box::new(TermQuery::new(t.clone(), IndexRecordOption::WithFreqs)) as Box<dyn Query>)
                .collect();
            let weight = DisjunctionMaxQuery::new(disjuncts).weight(enable_scoring)?;
            // tantivy 0.26.1: a top-level disjunction of term queries collects
            // top docs through block-WAND, which *sums* the terms and ignores
            // the max combiner — a doc with both `designers` and `design`
            // would score their sum. A boost of 1 hides `for_each_pruning`,
            // so collection goes through the scorer, which takes the max.
            return Ok(Box::new(BoostWeight::new(weight, 1.0)));
        }

        let patterns: Vec<(usize, String)> =
            self.positions.iter().map(|p| (p.offset, Self::pattern(p))).collect();
        let rescale = match &enable_scoring {
            EnableScoring::Enabled { statistics_provider, .. } => {
                Some(self.idf_rescale(*statistics_provider, &patterns)?)
            }
            EnableScoring::Disabled { .. } => None,
        };
        let alternatives: usize = self.positions.iter().map(|p| p.terms.len()).sum();
        let mut query = RegexPhraseQuery::new_with_offset_and_slop(self.field, patterns, self.slop);
        query.set_max_expansions(u32::try_from(alternatives).unwrap_or(u32::MAX));
        let weight = query.weight(enable_scoring)?;
        Ok(match rescale {
            Some(factor) => Box::new(BoostWeight::new(weight, factor)),
            None => weight,
        })
    }

    /// Every alternative, so snippets highlight whichever one a document has.
    fn query_terms<'a>(&'a self, visitor: &mut dyn FnMut(&'a Term, bool)) {
        for position in &self.positions {
            for term in &position.terms {
                visitor(term, true);
            }
        }
    }
}
