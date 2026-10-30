//! Hegel properties for Mila's shared model parsers (ADR-0265).
use hegel::{generators as gs, TestCase};
use mila_model::{Identifier, ModelError, RequestId, WorkspaceSource};

const HEX: &str = "0123456789abcdef";
const UUID_NOISE: &str = "0123456789abcdefABCDEFgz-{}:";

/// Independent oracle: the canonical lowercase hyphenated 8-4-4-4-12 spelling.
fn canonical_uuid_text(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

/// Independent oracle: `porsche-` followed by exactly 32 lowercase hex digits.
fn canonical_request_id(value: &str) -> bool {
    value.strip_prefix("porsche-").is_some_and(|suffix| {
        suffix.len() == 32
            && suffix
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-model-identifier-oracle
/// `Identifier::parse` MUST accept exactly the canonical lowercase hyphenated UUID
/// spelling, agreeing with an independent character-class oracle on generated
/// canonical, mutated and noise inputs, and MUST format back to its input.
#[hegel::test(test_cases = 256)]
fn identifier_parse_matches_canonical_oracle(tc: TestCase) {
    let canonical = tc.draw(gs::uuids());
    let parsed = Identifier::parse(&canonical).expect("canonical identifier");
    assert_eq!(parsed.to_string(), canonical);
    assert_eq!(parsed.uuid().to_string(), canonical);
    let upper = canonical.to_ascii_uppercase();
    assert_eq!(Identifier::parse(&upper).is_ok(), upper == canonical);

    let mut mutated: Vec<char> = canonical.chars().collect();
    let index = tc.draw(gs::integers::<usize>().max_value(mutated.len() - 1));
    mutated[index] = tc.draw(gs::sampled_from(UUID_NOISE.chars().collect::<Vec<_>>()));
    let mutated: String = mutated.into_iter().collect();
    let noise = tc.draw(gs::text().alphabet(UUID_NOISE).max_size(40));
    for candidate in [mutated, noise] {
        let result = Identifier::parse(&candidate);
        assert_eq!(result.is_ok(), canonical_uuid_text(&candidate));
        match result {
            Ok(identifier) => assert_eq!(identifier.to_string(), candidate),
            Err(error) => assert_eq!(error, ModelError::InvalidIdentifier),
        }
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-model-request-id-oracle
/// `RequestId::parse` MUST accept exactly `porsche-` plus 32 lowercase hex digits,
/// agreeing with an independent oracle, and MUST preserve the wire spelling.
#[hegel::test(test_cases = 256)]
fn request_id_parse_matches_canonical_oracle(tc: TestCase) {
    let digits = tc.draw(
        gs::vecs(gs::sampled_from(HEX.chars().collect::<Vec<_>>()))
            .min_size(32)
            .max_size(32),
    );
    let canonical = format!("porsche-{}", digits.into_iter().collect::<String>());
    let parsed = RequestId::parse(&canonical).expect("canonical request id");
    assert_eq!(parsed.as_str(), canonical);
    assert_eq!(parsed.to_string(), canonical);

    let prefix = tc.draw(gs::sampled_from(vec![
        "porsche-",
        "Porsche-",
        "porsche",
        "porsche--",
        "",
    ]));
    let suffix = tc.draw(gs::text().alphabet("0123456789abcdefABCDEFg-").max_size(40));
    let candidate = format!("{prefix}{suffix}");
    let result = RequestId::parse(&candidate);
    assert_eq!(result.is_ok(), canonical_request_id(&candidate));
    match result {
        Ok(id) => assert_eq!(id.as_str(), candidate),
        Err(error) => assert_eq!(error, ModelError::InvalidRequestId),
    }
}

fn label(tc: &TestCase) -> String {
    let edge = "abcXYZ019";
    let inner = "abcXYZ019-_.";
    let first = tc.draw(gs::sampled_from(edge.chars().collect::<Vec<_>>()));
    let middle = tc.draw(gs::text().alphabet(inner).max_size(98));
    let last = tc.draw(gs::optional(gs::sampled_from(
        edge.chars().collect::<Vec<_>>(),
    )));
    match last {
        Some(last) => format!("{first}{middle}{last}"),
        None => first.to_string(),
    }
}

/// @cc [owner:ghuntley,label:verification;protocol] mila-model-workspace-source-roundtrip
/// Every generated GitHub source with valid owner/repository labels MUST survive
/// `to_url` then `parse` unchanged (except the documented `.git` suffix trim on a
/// repository URL without a pull request), and every accepted URL MUST be canonical:
/// parsing its `to_url` yields the same source.
#[hegel::test(test_cases = 256)]
fn workspace_source_parse_to_url_round_trip(tc: TestCase) {
    let source = WorkspaceSource {
        owner: label(&tc),
        repository: label(&tc),
        pull_request: tc.draw(gs::optional(gs::integers::<u32>().min_value(1))),
    };
    let url = source.to_url();
    let reparsed = WorkspaceSource::parse(&url);
    #[expect(
        clippy::case_sensitive_file_extension_comparisons,
        reason = "mirrors parse's case-sensitive `.git` trim on a URL path, not a file name"
    )]
    let trimmed_by_parse = source.pull_request.is_none() && source.repository.ends_with(".git");
    if trimmed_by_parse {
        if let Ok(trimmed) = &reparsed {
            assert_eq!(trimmed.owner, source.owner);
            assert!(source.repository.starts_with(&trimmed.repository));
        }
    } else {
        assert_eq!(reparsed.as_ref(), Ok(&source));
    }

    let tail = tc.draw(gs::text().alphabet("ab09-_./?#%@\\pulgit").max_size(60));
    let candidate = format!("https://github.com/{tail}");
    match WorkspaceSource::parse(&candidate) {
        Ok(accepted) => {
            assert_eq!(WorkspaceSource::parse(&accepted.to_url()), Ok(accepted));
        }
        Err(error) => assert_eq!(error, ModelError::InvalidSource),
    }
}
