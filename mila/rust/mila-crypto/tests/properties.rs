//! Hegel properties for Mila's device-key primitives (ADR-0265).
use hegel::{generators as gs, TestCase};
use mila_crypto::{verify_public_key, CryptoError, DeviceKey};

/// The P-256 group order `n`, big-endian.
const ORDER: [u8; 32] = [
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
];

/// Independent oracle: a valid private scalar is non-zero and below the order.
fn valid_scalar(seed: &[u8; 32]) -> bool {
    seed.iter().any(|byte| *byte != 0) && seed.as_slice() < ORDER.as_slice()
}

/// Seeds biased towards the scalar-range boundaries as well as arbitrary bytes.
fn draw_seed(tc: &TestCase) -> [u8; 32] {
    let mut below = ORDER;
    below[31] -= 1;
    let mut one = [0u8; 32];
    one[31] = 1;
    let edge = tc.draw(gs::sampled_from(vec![
        None,
        Some([0u8; 32]),
        Some(one),
        Some(below),
        Some(ORDER),
        Some([0xff; 32]),
    ]));
    edge.unwrap_or_else(|| tc.draw(gs::default::<[u8; 32]>()))
}

/// Draws a seed the oracle accepts, so signing properties never discard.
fn draw_valid_seed(tc: &TestCase) -> [u8; 32] {
    let seed = tc.draw(gs::default::<[u8; 32]>());
    if valid_scalar(&seed) {
        seed
    } else {
        [0x11; 32]
    }
}

/// @cc [owner:ghuntley,label:verification;security] mila-crypto-seed-scalar-oracle
/// `DeviceKey::from_seed` MUST accept exactly the non-zero scalars below the
/// P-256 order and refuse every other seed as `InvalidKey`; an accepted key
/// MUST publish a 33-byte compressed SEC1 point.
#[hegel::test(test_cases = 128)]
fn from_seed_accepts_exactly_valid_scalars(tc: TestCase) {
    let seed = draw_seed(&tc);
    match DeviceKey::from_seed(seed) {
        Ok(key) => {
            assert!(valid_scalar(&seed), "an out-of-range seed was accepted");
            let point = key.public_key_sec1();
            assert!(matches!(point[0], 0x02 | 0x03), "point is not compressed");
        }
        Err(error) => {
            assert_eq!(error, CryptoError::InvalidKey);
            assert!(!valid_scalar(&seed), "a valid seed was refused");
        }
    }
}

/// @cc [owner:ghuntley,label:verification;security] mila-crypto-signature-round-trip
/// A DER signature from `DeviceKey::sign` MUST verify for the signed message
/// through both `DeviceKey::verify` and `verify_public_key` with the published
/// point, and MUST NOT verify for any different message.
#[hegel::test(test_cases = 64)]
fn signatures_round_trip_and_bind_the_message(tc: TestCase) {
    let key = DeviceKey::from_seed(draw_valid_seed(&tc)).expect("oracle-valid scalar");
    let message = tc.draw(gs::vecs(gs::default::<u8>()).max_size(256));
    let other = tc.draw(gs::vecs(gs::default::<u8>()).max_size(256));
    let signature = key.sign(&message);
    let point = key.public_key_sec1();
    assert!(key.verify(&message, &signature));
    assert_eq!(verify_public_key(&point, &message, &signature), Ok(true));
    if other != message {
        assert!(!key.verify(&other, &signature));
        assert_eq!(verify_public_key(&point, &other, &signature), Ok(false));
    }
}

/// @cc [owner:ghuntley,label:verification;security] mila-crypto-verify-fail-closed
/// Verification MUST be total over arbitrary signature and public-key bytes:
/// `verify_public_key` refuses a malformed point as `InvalidKey`, a malformed
/// signature as `InvalidSignature`, and otherwise agrees with
/// `DeviceKey::verify`; a corrupted signature MUST NOT verify.
#[hegel::test(test_cases = 64)]
fn verification_is_total_and_fail_closed(tc: TestCase) {
    let key = DeviceKey::from_seed(draw_valid_seed(&tc)).expect("oracle-valid scalar");
    let message = tc.draw(gs::vecs(gs::default::<u8>()).max_size(128));
    let mut signature = key.sign(&message);
    let corrupt = tc.draw(gs::booleans());
    if corrupt {
        let index = tc.draw(gs::integers::<usize>().max_value(signature.len() - 1));
        let flip = tc.draw(gs::integers::<u8>().min_value(1));
        signature[index] ^= flip;
    }
    let use_signature = tc.draw(gs::booleans());
    let candidate = if use_signature {
        signature
    } else {
        tc.draw(gs::vecs(gs::default::<u8>()).max_size(80))
    };
    let accepted = key.verify(&message, &candidate);
    if use_signature {
        assert_eq!(accepted, !corrupt, "corruption changed the verdict wrongly");
    }
    match verify_public_key(&key.public_key_sec1(), &message, &candidate) {
        Ok(verified) => assert_eq!(verified, accepted),
        Err(error) => {
            assert_eq!(error, CryptoError::InvalidSignature);
            assert!(!accepted);
        }
    }
    let point = tc.draw(gs::vecs(gs::default::<u8>()).max_size(80));
    if let Err(error) = verify_public_key(&point, &message, &key.sign(&message)) {
        assert_eq!(error, CryptoError::InvalidKey);
    }
}
