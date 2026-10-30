use super::*;
use hegel::generators as gs;
use hegel::generators::Generator as _;
use hegel::TestCase;

/// @cc [owner:ghuntley,label:verification] hegel-side-classifier-lattice
/// The outcome lattice is fully enumerable: five side pairs must terminate and
/// only the jointly-observed pairings resolve.
#[hegel::test(test_cases = 100)]
fn outcome_classifier_matches_the_closed_lattice(_tc: TestCase) {
    use Side::{Failed, Running, Succeeded};
    assert_eq!(Failed.classify(Failed), Some(7));
    assert_eq!(Failed.classify(Running), Some(5));
    assert_eq!(Failed.classify(Succeeded), Some(5));
    assert_eq!(Running.classify(Failed), Some(6));
    assert_eq!(Succeeded.classify(Failed), Some(6));
    assert_eq!(Succeeded.classify(Succeeded), Some(0));
    assert_eq!(Running.classify(Running), None);
    assert_eq!(Running.classify(Succeeded), None);
    assert_eq!(Succeeded.classify(Running), None);
    let states = [Running, Succeeded, Failed];
    for first in states {
        for second in states {
            let expected = match (first, second) {
                (Failed, Failed) => Some(7),
                (Failed, _) => Some(5),
                (_, Failed) => Some(6),
                (Succeeded, Succeeded) => Some(0),
                _ => None,
            };
            assert_eq!(first.classify(second), expected);
        }
    }
}

type Selected = (u64, u64, Option<i32>, Option<u32>, Option<u32>);

/// The independent selector specification.
fn oracle(words: &[OsString]) -> Option<Selected> {
    let [timeout, rate, progress, producer_uid, consumer_uid, producers, rest @ ..] = words else {
        return None;
    };
    let decimal = |text: &OsString, min: u64, max: u64| -> Option<u64> {
        let text = text.to_str()?;
        if text.is_empty()
            || !text.bytes().all(|b| b.is_ascii_digit())
            || (text.len() > 1 && text.starts_with('0'))
        {
            return None;
        }
        text.parse::<u64>().ok().filter(|v| (min..=max).contains(v))
    };
    let dash = |text: &OsString, min: u64, max: u64| -> Option<Option<u64>> {
        if text == "-" {
            Some(None)
        } else {
            decimal(text, min, max).map(Some)
        }
    };
    let t = decimal(timeout, 1000, 86_400_000)?;
    let r = decimal(rate, 0, 1_073_741_824)?;
    let progress = dash(progress, 3, 1023)?.map(|fd| fd as i32);
    let producer_uid = dash(producer_uid, 1, 4_294_967_294)?.map(|uid| uid as u32);
    let consumer_uid = dash(consumer_uid, 1, 4_294_967_294)?.map(|uid| uid as u32);
    let split = usize::try_from(decimal(producers, 1, 128)?).ok()?;
    if rest.len() < split + 1 || rest.len() - split > CONSUMER_ARGS_LIMIT {
        return None;
    }
    let producer = &rest[..split];
    let consumer = &rest[split..];
    if !producer[0].as_os_str().as_bytes().starts_with(b"/")
        || !consumer[0].as_os_str().as_bytes().starts_with(b"/")
        || producer
            .iter()
            .chain(consumer.iter())
            .any(|a| a.is_empty() || a.as_os_str().as_bytes().contains(&0))
    {
        return None;
    }
    Some((t, r, progress, producer_uid, consumer_uid))
}

/// @cc [owner:ghuntley,label:verification] hegel-transfer-selector-oracle
/// Generated argv vectors MUST classify against the independent selector spec:
/// bounded timeout, rate, progress descriptor and side uids (never root),
/// absolute producer/consumer heads and bounded counts.
#[hegel::test(test_cases = 100)]
fn cli_selector_matches_independent_oracle(tc: TestCase) {
    let base = ["1000", "0", "-", "-", "977", "1", "/prod/0", "/cons/0"];
    let argc = tc.draw(gs::integers::<usize>().min_value(0).max_value(12));
    let mut words: Vec<OsString> = Vec::new();
    for index in 0..argc {
        let candidate = if index < base.len() && tc.draw(gs::booleans()) {
            base[index].to_string()
        } else {
            tc.draw(gs::sampled_from(&[
                "",
                "-",
                "/",
                "x",
                "0",
                "1",
                "2",
                "3",
                "999",
                "1000",
                "1023",
                "1024",
                "86400000",
                "86400001",
                "1073741824",
                "1073741825",
                "4294967294",
                "4294967295",
                "129",
                "/prod",
                "/cons",
                "otra",
                "01",
            ]))
            .to_string()
        };
        words.push(OsString::from(candidate));
    }
    match (parse_cli(&words), oracle(&words)) {
        (None, None) => {}
        (Some(request), Some((timeout, rate, progress, producer_uid, consumer_uid))) => {
            assert_eq!(request.timeout_ms, timeout);
            assert_eq!(request.rate, rate);
            assert_eq!(request.progress, progress);
            assert_eq!(request.producer_uid, producer_uid);
            assert_eq!(request.consumer_uid, consumer_uid);
            assert_eq!(
                request.producer.len() + request.consumer.len(),
                words.len() - 6
            );
        }
        (parsed, expected) => panic!("diverged: parsed={parsed:?} expected={expected:?}"),
    }
}

/// The independent refill specification, in wide arithmetic.
fn refill_oracle(credit: i64, elapsed_ms: i64, rate: u64) -> i64 {
    if rate == 0 || elapsed_ms <= 0 {
        return credit;
    }
    let grown = i128::from(credit) + i128::from(elapsed_ms.min(1000)) * i128::from(rate);
    i64::try_from(grown.min(i128::from(CREDIT_CAP_MS))).expect("capped credit fits")
}

/// @cc [owner:ghuntley,label:verification] hegel-transfer-credit-throttle-bounds
/// Generated refill/splice schedules MUST keep throttle credit within
/// 0..=CREDIT_CAP_MS, match the independent wide-arithmetic refill oracle, and
/// never open a splice window beyond credit/1000 bytes (or SPLICE_WINDOW).
#[hegel::test(test_cases = 200)]
fn credit_throttle_stays_bounded(tc: TestCase) {
    let rate = tc.draw(gs::one_of(vec![
        gs::just(0_u64).boxed(),
        gs::integers::<u64>().min_value(1).max_value(4096).boxed(),
        gs::integers::<u64>()
            .min_value(1)
            .max_value(u64::try_from(RATE_LIMIT).expect("rate limit fits"))
            .boxed(),
    ]));
    let steps = tc.draw(gs::integers::<usize>().min_value(1).max_value(32));
    let mut credit = CREDIT_CAP_MS;
    for _ in 0..steps {
        let elapsed = tc.draw(gs::integers::<i64>().min_value(-2).max_value(5000));
        let refilled = refill(credit, elapsed, rate);
        assert_eq!(refilled, refill_oracle(credit, elapsed, rate));
        credit = refilled;
        assert!((0..=CREDIT_CAP_MS).contains(&credit));
        let available = window(credit, rate);
        assert!(available <= SPLICE_WINDOW);
        if rate != 0 {
            assert!(available <= usize::try_from(credit / 1000).expect("credit is non-negative"));
        } else {
            assert_eq!(available, SPLICE_WINDOW);
        }
        let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(available));
        credit = debit(credit, count, rate);
        assert!((0..=CREDIT_CAP_MS).contains(&credit));
    }
}

/// Root is never an accepted side uid, whatever else is valid.
#[test]
fn root_side_uid_is_refused() {
    let words = |uid: &str| -> Vec<OsString> {
        ["1000", "0", "-", uid, "-", "1", "/p", "/c"]
            .iter()
            .map(OsString::from)
            .collect()
    };
    assert!(parse_cli(&words("0")).is_none());
    assert!(parse_cli(&words("977")).is_some());
}
