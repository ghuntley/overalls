//! Hegel properties for the private route component codec (ADR-0265).
use super::{decode_component, encode_component};
use hegel::{generators as gs, TestCase};

/// @cc [owner:ghuntley,label:verification;protocol] mila-model-component-codec-roundtrip
/// `decode_component(encode_component(s))` MUST return `s` for any Unicode text,
/// the encoding MUST contain only unreserved ASCII and `%XX` escapes with uppercase
/// hex, and decoding arbitrary percent-noise MUST never panic.
#[hegel::test(test_cases = 256)]
fn component_codec_round_trips(tc: TestCase) {
    let value = tc.draw(gs::text().max_size(64));
    let encoded = encode_component(&value);
    assert!(encoded
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"-_.~%".contains(&byte)));
    let mut escapes = encoded.split('%').skip(1);
    assert!(escapes.all(|escape| escape.len() >= 2
        && escape
            .bytes()
            .take(2)
            .all(|byte| byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte))));
    assert_eq!(decode_component(&encoded).as_deref(), Some(value.as_str()));

    let noise = tc.draw(gs::text().alphabet("%0aF+gz~é").max_size(32));
    if let Some(decoded) = decode_component(&noise) {
        if !noise.contains('%') {
            assert_eq!(decoded, noise.replace('+', " "));
        }
    }
}
