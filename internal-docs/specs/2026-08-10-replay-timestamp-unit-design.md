# Replay timestamp `unit:` — design

PRO-3095: https://linear.app/teamshares/issue/PRO-3095

## Problem

`verify :hmac, replay: { timestamp:, within: }` resolves `timestamp` and feeds it to
`Signature.within_tolerance?` → `coerce_epoch`, which only understands epoch **seconds**:

```ruby
def coerce_epoch(timestamp)
  case timestamp
  when Time    then timestamp.to_i
  when Integer then timestamp
  when String  then (Integer(timestamp, 10) if timestamp.match?(/\A-?\d+\z/))
  end
end
```

Lob's timestamp header is epoch **milliseconds**, so the only way to make replay protection work
today is a hand-rolled conversion at the call site:

```ruby
replay: { timestamp: ->(request) { lob_timestamp.call(request)[0, 10] }, within: 5.minutes }
```

String-slicing the first 10 characters assumes an exact digit count rather than doing arithmetic,
and breaks silently if the header's shape ever changes. This isn't Lob-specific — any vendor
sending sub-second-resolution epochs hits the same workaround today.

## Decision

Add a `unit:` option, threaded from `verify :hmac`'s `replay:` hash down to
`Signature.coerce_epoch`, defaulting to `:seconds` everywhere (fully backward-compatible).

```ruby
replay: { timestamp: ->(request) { lob_timestamp.call(request) }, within: 5.minutes, unit: :ms }
```

### Supported units

Mirrors the existing `DIGESTS` constant style in `signature.rb` — a frozen Hash mapping unit name
to its divisor, so adding a unit later is a one-line change:

```ruby
UNITS = { seconds: 1, ms: 1_000, milliseconds: 1_000, microseconds: 1_000_000 }.freeze
```

`:ms` and `:milliseconds` are synonyms. An unrecognized `unit:` raises `ArgumentError`, matching
the existing `openssl_digest`/`encode` pattern (loud developer error, not silent fallback).

### Where conversion happens

- `coerce_epoch(timestamp, unit)`:
  - `Time` → `.to_i`, **unit ignored** (a `Time` object is already unambiguous; there is no
    "millisecond Time").
  - `Integer` → `timestamp / UNITS.fetch(unit)`.
  - `String` → parsed to `Integer` (existing digit-string regex), then same division.
- `within_tolerance?(timestamp:, tolerance:, now: nil, unit: :seconds)` passes `unit` through to
  `coerce_epoch`. Comparison against `now` stays in seconds — only the incoming epoch is scaled
  down, `tolerance:` keeps its current (seconds) meaning unchanged.
- `Signature.hmac(..., unit: :seconds)` gains the same keyword, passed through to
  `within_tolerance?`.
- `Verifiers.register(:hmac)`: `unit: replay&.fetch(:unit, :seconds)`, passed to `Signature.hmac`.

Division is integer (floor), not rounded — replay tolerance windows are always many seconds to
minutes, so sub-second floor error is immaterial.

### Rejected alternatives

1. **Auto-detect unit by magnitude** (e.g. treat ≥13-digit epochs as ms). Rejected — this
   re-implements the exact "assume digit count" fragility the ticket exists to eliminate, just
   moved from the call site into the library.
2. **Leave the primitive alone, document the workaround better.** Rejected — doesn't fix
   anything; every ms-epoch vendor still hand-rolls the same conversion, which is the actual bug.

## Testing

TDD, failing test first, per `AGENTS.md`.

- `spec/axn/webhooks/signature_spec.rb`:
  - ms timestamp accepted within tolerance, rejected outside tolerance (boundary cases mirroring
    the existing seconds-based replay-window tests).
  - `:ms` and `:milliseconds` behave identically.
  - `Time`/`Integer`/`String` inputs still default correctly to `:seconds` when `unit:` is
    omitted (regression coverage for the existing behavior).
  - unrecognized `unit:` raises `ArgumentError`.
- `spec/axn/webhooks/verifiers/hmac_spec.rb`:
  - a Lob-shaped scenario: `replay: { timestamp: header("X-Ts"), within: 300, unit: :ms }` with a
    millisecond-epoch header, accepted when fresh — replacing the need for the `[0, 10]` slice
    workaround the ticket calls out.

## Docs

- README: no dedicated `replay:` section exists today (only a one-line comment on the low-level
  `Signature.hmac` example). Add a short subsection under "Signature primitive" documenting
  `timestamp:`/`tolerance:`/`unit:`, and mention `unit:` on `verify :hmac`'s `replay:` hash.
- CHANGELOG: `[Unreleased] → Added` entry.

## Scope

Out of scope: `standard_webhooks.rb`'s `webhook-timestamp` is always seconds per the Standard
Webhooks (Svix) spec — no `unit:` needed there.
