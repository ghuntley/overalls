# Android display stream generation and frame bounds

**Property:** The Android display stream accepts only positive, bounded data/input frames for the current generation. A stale generation, mismatched declared length, unknown kind, zero-sized payload, or payload beyond the configured window is rejected before any relay or guest forwarding.

**Source evidence:** `protocol/lib/overalls_protocol/android_display_stream.ex:1-58` defines the 262,144-byte display-data limit, 4,096-byte input limit, generation equality check, sequence positivity, exact length check, and key/pointer kind restriction. `lilly/test/network/android_display_test.exs:1-26` confirms current-generation target selection and stale-generation/disabled-display refusal at the network target layer. The catalog currently has no Android display stream property.

**Assertion choice:** Use `Always` for every decoder/forwarding decision: malformed or stale input must never cross the boundary. Add a `Reachable` search anchor when a delayed old-generation frame is presented after a generation transition, because the fault must reach the decoder's rejection branch before the invariant is informative.

**Independent oracle and fault recipe:** Run a real display-capable guest/relay fixture with an external frame ledger. Establish a current generation and record accepted data/input nonces. Rotate the display generation, then deliver delayed old-generation frames, altered lengths, unknown version/kind bytes, and payloads at limit and limit+1. The ledger must show no forwarding for rejected frames; accepted boundary-sized frames must preserve nonce, generation, sequence and exact bytes. Inspect decoder result and relay writes separately so a client disconnect is not mistaken for rejection.

**Open question / investigation log:** The codec and stale target-selection behavior are source-backed, but the production relay/guest consumer and an independent end-to-end forwarding fixture were not found in the current scan. This is partial evidence; resolve by tracing the Android display route and adding a fixture that records bytes outside the decoder under test.
