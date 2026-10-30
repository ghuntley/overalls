//! Hegel properties for Mila's shared locale policy (ADR-0265).
use hegel::{generators as gs, TestCase};
use mila_localization::{
    choose, direction, negotiate, normalize, Direction, Locale, DEFAULT_LOCALE, SUPPORTED_LOCALES,
};

/// @cc [owner:ghuntley,label:verification;localization] mila-localization-normalize-canonical
/// `normalize` MUST map arbitrary text either to a supported canonical locale
/// that `Locale::parse` accepts unchanged, or to a deterministic rejection.
#[hegel::test(test_cases = 128)]
fn normalized_locale_is_canonical_or_rejected(tc: TestCase) {
    let input =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(200))).into_owned();
    match normalize(&input) {
        Some(canonical) => {
            assert!(SUPPORTED_LOCALES.contains(&canonical.as_str()));
            assert_eq!(Locale::parse(&canonical).unwrap().as_str(), canonical);
            assert!(canonical.is_ascii());
        }
        None => {
            // Rejection must be deterministic: parsing the same input cannot succeed.
            assert!(Locale::parse(&input).is_none());
        }
    }
}

/// @cc [owner:ghuntley,label:verification;localization] mila-localization-direction-total
/// `direction` MUST be total and stable, right-to-left exactly for the
/// supported `ar`, `arz` and `ur` locales and left-to-right otherwise.
#[hegel::test(test_cases = 128)]
fn locale_direction_is_total_and_stable(tc: TestCase) {
    let input =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(200))).into_owned();
    let first = direction(&input);
    let second = direction(&input);
    assert_eq!(first, second);
    if let Some(locale) = Locale::parse(&input) {
        if matches!(locale.as_str(), "ar" | "arz" | "ur") {
            assert_eq!(first, Direction::Rtl);
        } else {
            assert_eq!(first, Direction::Ltr);
        }
    } else {
        assert_eq!(first, Direction::Ltr);
    }
}

/// A supported, unsupported or malformed tag without list or parameter
/// separators.
fn draw_pool_tag(tc: &TestCase) -> String {
    let mut pool: Vec<String> = SUPPORTED_LOCALES.iter().map(|x| (*x).to_owned()).collect();
    pool.extend(["pt", "zh", "EN_us", "ar-EG", "xx", "", " ", "*", "de-CH"].map(str::to_owned));
    tc.draw(gs::sampled_from(pool))
}

/// Pool tags plus arbitrary text, so headers mix supported, unsupported and
/// malformed entries.
fn draw_tag(tc: &TestCase) -> String {
    if tc.draw(gs::booleans()) {
        draw_pool_tag(tc)
    } else {
        tc.draw(gs::text().max_size(16))
    }
}

fn draw_header(tc: &TestCase) -> String {
    let count = tc.draw(gs::integers::<usize>().max_value(5));
    let mut parts = Vec::with_capacity(count);
    for _ in 0..count {
        let tag = draw_tag(tc);
        let quality = tc.draw(gs::sampled_from(vec![
            "", ";q=0", ";q=0.0", ";q=0.5", ";q=1", ";q=bad", "; q=0.9",
        ]));
        parts.push(format!("{tag}{quality}"));
    }
    parts.join(",")
}

/// @cc [owner:ghuntley,label:verification;localization] mila-localization-negotiate-supported
/// `negotiate` MUST be total over arbitrary Accept-Language text and return
/// only a supported locale; headers over 8192 bytes and headers whose every
/// entry has zero quality MUST yield no locale.
#[hegel::test(test_cases = 128)]
fn negotiation_returns_only_supported_locales(tc: TestCase) {
    let header = if tc.draw(gs::booleans()) {
        draw_header(&tc)
    } else {
        tc.draw(gs::text().max_size(200))
    };
    if let Some(locale) = negotiate(&header) {
        assert!(SUPPORTED_LOCALES.contains(&locale.as_str()));
    }
    let padded = format!("{header},{}", "x".repeat(8193));
    assert_eq!(negotiate(&padded), None);
    let tag = draw_pool_tag(&tc);
    assert_eq!(negotiate(&format!("{tag};q=0, en;q=0")), None);
}

/// @cc [owner:ghuntley,label:verification;localization] mila-localization-choose-precedence
/// `choose` MUST always return a supported locale, preferring a valid user
/// override, then a valid session locale, then Accept-Language negotiation,
/// then the default `en`.
#[hegel::test(test_cases = 128)]
fn choose_is_total_and_honours_precedence(tc: TestCase) {
    let user = tc.draw(gs::booleans()).then(|| draw_tag(&tc));
    let session = tc.draw(gs::booleans()).then(|| draw_tag(&tc));
    let header = tc.draw(gs::booleans()).then(|| draw_header(&tc));
    let chosen = choose(user.as_deref(), session.as_deref(), header.as_deref());
    assert!(SUPPORTED_LOCALES.contains(&chosen.as_str()));
    let expected = user
        .as_deref()
        .and_then(Locale::parse)
        .or_else(|| session.as_deref().and_then(Locale::parse))
        .or_else(|| header.as_deref().and_then(negotiate))
        .map_or_else(|| DEFAULT_LOCALE.to_owned(), |x| x.as_str().to_owned());
    assert_eq!(chosen.as_str(), expected);
}
