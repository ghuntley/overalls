//! Hegel properties for the private lexer and quoting (ADR-0265).
use crate::lex::{lex, quote};
use hegel::{generators as gs, TestCase};

/// @cc [owner:ghuntley,label:verification;protocol;security] mila-protocol-lex-quote-roundtrip
/// Lexing the space-joined `quote` of any non-empty tokens MUST return exactly
/// those tokens, and lexing arbitrary text MUST never panic or yield an empty token.
#[hegel::test(test_cases = 512)]
fn lex_quote_round_trip(tc: TestCase) {
    let tokens = tc.draw(gs::vecs(gs::text().min_size(1).max_size(24)).max_size(8));
    let line = tokens
        .iter()
        .map(|token| quote(token))
        .collect::<Vec<_>>()
        .join(" ");
    assert_eq!(lex(&line), Ok(tokens));

    let arbitrary = tc.draw(gs::text().alphabet("ab \t'\"\\-=").max_size(48));
    if let Ok(tokens) = lex(&arbitrary) {
        assert!(tokens.iter().all(|token| !token.is_empty()));
    }
}
