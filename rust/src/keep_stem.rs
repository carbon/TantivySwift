//! `KeepStemFilter`: keyword-repeat stemming for one field.
//!
//! Lucene gets this from `KeywordRepeatFilter` → `Stemmer` → `RemoveDuplicates`.
//! Here it is one filter: each token is emitted as it arrives, then — only when
//! the stem differs — again as its stem, at the same position and offsets. One
//! field then answers exact, stemmed, prefix and phrase queries.

use rust_stemmers::{Algorithm, Stemmer};
use tantivy::tokenizer::{Token, TokenFilter, TokenStream, Tokenizer};

/// Emits each token, then its stem at the same position — only when the stem
/// differs. `poster` is stored once; `designer` as `designer` + `design`.
///
/// Like tantivy's `Stemmer`, it expects lowercased input.
#[derive(Clone)]
pub struct KeepStemFilter {
    algorithm: Algorithm,
}

impl KeepStemFilter {
    /// The English (Porter2) stemmer — the one tantivy's `en_stem` uses.
    pub fn english() -> Self {
        KeepStemFilter { algorithm: Algorithm::English }
    }
}

impl TokenFilter for KeepStemFilter {
    type Tokenizer<T: Tokenizer> = KeepStemFilterWrapper<T>;

    fn transform<T: Tokenizer>(self, tokenizer: T) -> KeepStemFilterWrapper<T> {
        KeepStemFilterWrapper { algorithm: self.algorithm, inner: tokenizer }
    }
}

#[derive(Clone)]
pub struct KeepStemFilterWrapper<T> {
    algorithm: Algorithm,
    inner: T,
}

impl<T: Tokenizer> Tokenizer for KeepStemFilterWrapper<T> {
    type TokenStream<'a> = KeepStemTokenStream<T::TokenStream<'a>>;

    fn token_stream<'a>(&'a mut self, text: &'a str) -> Self::TokenStream<'a> {
        KeepStemTokenStream {
            tail: self.inner.token_stream(text),
            stemmer: Stemmer::create(self.algorithm),
            stem: Token::default(),
            stem_pending: false,
            on_stem: false,
        }
    }
}

/// Holds at most one pending token — the stem of the token the tail is on.
pub struct KeepStemTokenStream<T> {
    tail: T,
    stemmer: Stemmer,
    /// Reused across tokens so its `text` allocation is kept.
    stem: Token,
    /// `stem` belongs to the current tail token and has not been emitted yet.
    stem_pending: bool,
    /// The stream is currently yielding `stem` rather than the tail's token.
    on_stem: bool,
}

impl<T: TokenStream> TokenStream for KeepStemTokenStream<T> {
    fn advance(&mut self) -> bool {
        if self.stem_pending {
            self.stem_pending = false;
            self.on_stem = true;
            return true;
        }
        self.on_stem = false;

        if !self.tail.advance() {
            return false;
        }
        let token = self.tail.token();
        let stemmed = self.stemmer.stem(&token.text);
        if stemmed.as_ref() != token.text.as_str() {
            let mut text = std::mem::take(&mut self.stem.text);
            text.clear();
            text.push_str(&stemmed);
            self.stem = Token { text, ..*token };
            self.stem_pending = true;
        }
        true
    }

    fn token(&self) -> &Token {
        if self.on_stem {
            &self.stem
        } else {
            self.tail.token()
        }
    }

    fn token_mut(&mut self) -> &mut Token {
        if self.on_stem {
            &mut self.stem
        } else {
            self.tail.token_mut()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tantivy::tokenizer::{LowerCaser, SimpleTokenizer, TextAnalyzer};

    fn tokens(text: &str) -> Vec<(String, usize, usize, usize)> {
        let mut analyzer = TextAnalyzer::builder(SimpleTokenizer::default())
            .filter(LowerCaser)
            .filter(KeepStemFilter::english())
            .build();
        let mut stream = analyzer.token_stream(text);
        let mut out = Vec::new();
        while stream.advance() {
            let t = stream.token();
            out.push((t.text.clone(), t.position, t.offset_from, t.offset_to));
        }
        out
    }

    #[test]
    fn keeps_surface_and_stem_at_one_position() {
        assert_eq!(
            tokens("Graphic Designers"),
            vec![
                ("graphic".into(), 0, 0, 7),
                ("designers".into(), 1, 8, 17),
                ("design".into(), 1, 8, 17),
            ]
        );
    }

    #[test]
    fn a_word_that_stems_to_itself_is_emitted_once() {
        assert_eq!(tokens("poster"), vec![("poster".into(), 0, 0, 6)]);
    }

    #[test]
    fn empty_text_yields_nothing() {
        assert!(tokens("").is_empty());
    }
}
