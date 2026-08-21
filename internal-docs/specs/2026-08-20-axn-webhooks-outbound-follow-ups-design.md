# PRO-3211 outbound design follow-ups — design

Five independent items from [PRO-3211](https://linear.app/teamshares/issue/PRO-3211). They share a
ticket, not a mechanism; each stands alone and can ship alone. Ordered here by dependency (none) and
by size (ascending), which is also the recommended build order.

Two items originally in PRO-3211 are **not** here: per-subscriber signing/auth and the SSRF guard
moved to [PRO-3214](https://linear.app/teamshares/issue/PRO-3214) (DB-backed subscription store),
where they belong with the store they're blocked on.

## 1. `Config` immutability

`Outbound::Config` documents itself "immutable" (`config.rb:6`) but is plain unfrozen ivars, and
`Outbound.install` is a bare `@config` assignment. Make the comment true rather than downgrading it.

**A naive `freeze` breaks reads.** Verified empirically: `Axn::Configurable` lazily memoizes a
static default into an ivar on first read, so any setting the `outbound` block did not explicitly
assign (`max_attempts`, `vendor`, `user_agent`, `open_timeout`, `read_timeout` in a minimal block)
raises `FrozenError` **on read** if the object was frozen first. `backoff` and `transport` survive
because their defaults are dynamic (`-> { … }`) and recomputed rather than memoized — an
inconsistency to design around, not rely on.

Approach, at the end of `Config#initialize`:

1. Read all seven settings once, forcing the memo ivars into existence.
2. Freeze `@events` and each event spec Hash.
3. `freeze` self.

Freeze **containers only** — never the caller's callables, injected transport, or a `to:` resolver.
Freezing a statically-declared `to:` Array is in scope (it's ours once validated); freezing a Proc
the app handed us is not.

Verified against a frozen instance: all seven settings read correctly, `targets_for` / `wire_type` /
`vendor_for` work, an unknown event still raises `Axn::Webhooks::Error`, a setter raises
`FrozenError`, and a full `emit` → `Deliver` → transport round-trip succeeds.

For `install`: a `Mutex` around `install`/`reset!` only. **`config` reads stay unsynchronized** —
safe precisely because what's published is frozen, and `config` is read on every delivery attempt,
so a lock there is real overhead protecting nothing.

## 2. Sync-fallback outcome reporting (`failed_count`)

`Emit`'s fan-out calls `Deliver.call(**)` (non-bang) on the no-adapter sync path and discards the
result, so a failed delivery still leaves `emit`'s result `ok` with the target counted as delivered.
The once-per-emit warning names the degraded *mode*, never a failure.

Capture the result and expose a count:

```ruby
exposes :failed_count, type: Integer, default: 0
```

Two decisions, both deliberate and both **documented in the README**:

* **Always `0` on the async path.** Nothing has failed *at emit time*; failures happen later and
  `Deliver` reports them itself (exhaustion via `on_exception`, permanent 4xx via its own result).
  The honest alternative — `nil` when async — turns every `result.failed_count > 0` into a
  `NoMethodError`, so the footgun costs more than the precision buys.
* **`emit`'s result stays `ok` even when deliveries failed.** Fan-out succeeded; a subscriber being
  down is not an emit failure. The count is the surface, not the outcome.

`target_count` keeps its current meaning (targets resolved and enqueued), so
`target_count - failed_count` is the sync-path success count.

## 3. `sign :hmac` preset

Only `:standard_webhooks` and a raw custom block exist. A receiver expecting a plain
`X-Signature: <hex>` needs a hand-written signer today.

```ruby
# minimal — one header, body only
sign :hmac, secret: -> { ENV.fetch("PARTNER_SECRET") }, header: "X-Signature"
# => X-Signature: 3f9a1c…      (hex sha256 of the raw body)

# …or opt into a replay-protectable signature, Slack-style
sign :hmac,
     secret:           -> { ENV.fetch("SLACK_SIGNING_SECRET") },
     header:           "X-Signature",
     timestamp_header: "X-Timestamp",
     signing_string:   "v0:{timestamp}:{body}",
     prefix:           "v0="
# => X-Timestamp: 1755740000
#    X-Signature: v0=3f9a1c…
```

Options, mirroring `Verifiers::Hmac` where they overlap:

| Option | Default | Notes |
| -- | -- | -- |
| `secret:` | required | Plain value or zero-arity callable, re-resolved per attempt (same as `:standard_webhooks`; arity-validated at boot via `CallableArity`) |
| `header:` | required | No universal default exists; inbound requires `signature:` explicitly for the same reason |
| `digest:` | `:sha256` | |
| `encoding:` | `:hex` | |
| `prefix:` | `nil` | Prepended to the emitted signature |
| `signing_string:` | `"{body}"` | Template over `{timestamp}` and `{body}` |
| `timestamp_header:` | `nil` | Emitted only when named |

**`signing_string:` is a template, not a callable**, deliberately: an unknown `{placeholder}` is
rejected at declaration time, which a lambda makes impossible. A caller who genuinely needs
arbitrary logic already has the custom `sign { … }` block — a callable option here would be a
worse-ergonomics duplicate of an existing escape hatch.

Rejected: emitting no timestamp at all (option A in brainstorming). A preset whose output can never
be replay-protected sits badly in a gem that spends a README section on inbound replay windows. The
timestamp keys are optional, so the minimal form is unchanged.

Signing uses `Signature.compute`, the same primitive `:standard_webhooks` and the inbound `:hmac`
verifier use — so `sign :hmac` and `verify :hmac` round-trip against each other with matching
options, which is the integration test.

Boot-time validation (`ArgumentError`, matching the misconfiguration/runtime split the rest of
outbound uses): missing `header:`, an unknown template placeholder, `signing_string:` referencing
`{timestamp}` with no `timestamp_header:` declared (the receiver could not reconstruct the string),
and a `secret:` callable of the wrong arity.

## 4. Per-emit overrides

Everything is fixed at `outbound`-block declaration time; inbound has `mode:` and per-route `async:`
overrides with no outbound equivalent.

```ruby
Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 },
                   to:    "https://one-off.example/hook",  # String or Array
                   async: false)
```

* **`to:` replaces resolution entirely** for that call — the declared `to:`/`subscribers` is not
  consulted and not appended to. Same no-silent-merge stance `Config#targets_for` already takes. The
  event must still be declared (it supplies the wire `type` and `vendor`). A one-off URL gets the
  same http(s) validation a static `to:` gets at boot, applied here at emit time and raising
  `Axn::Webhooks::Error` (a runtime condition a caller may rescue, unlike a boot-time
  `ArgumentError`).
* **`async: true` with no adapter configured raises.** This is the explicit-request rule documented
  in the README (README "per-route sync/async"): a missing adapter degrades to sync only under
  `:auto`, never under an explicit request. **`async: false`** forces the inline path *and*
  suppresses the once-per-emit fallback warning — a caller asking for sync is not degraded.
  Omitted keeps today's `:auto`.

**`headers:` is deliberately excluded**, and belongs to PRO-3214. A per-emit `headers:` Hash is the
obvious place to hang a bearer token, and it would be threaded to `Deliver` as an `expects` — which
means it is serialized into the async job's args and persists in the queue, in plaintext, for the
whole retry lifetime. That is the opposite of the convention `secret:` follows (a callable
re-resolved per attempt, never stored). PRO-3214 owns per-destination config and should apply the
callable convention to it; shipping a Hash-shaped version first would land the feature twice in
incompatible shapes. The PRO-3214 session has been notified.

## 5. Nested `inbound` declarations

A parent `verify` declared once, with children adding their own `dispatch`/`respond`.

```ruby
Axn::Webhooks.inbound :slack do
  verify :hmac, secret: ENV.fetch("SLACK_SIGNING_SECRET"), prefix: "v0=",
                replay: { timestamp: header("X-Slack-Request-Timestamp"), within: 300 }
  challenge_required { |req| req.params["type"] == "url_verification" }

  endpoint :interactivity do
    dispatch on: ->(e) { e["type"] }, to: { "block_actions" => async("Handle") }
    respond { |r| json(r.response_action) }
  end

  endpoint :events do
    dispatch on: ->(e) { e.dig("event", "type") }, to: { "app_mention" => "Mention" }
    verify :hmac, secret: ENV.fetch("SLACK_ALT_SECRET"), prefix: "v0="  # child override wins
  end
end
# => Inbound[:slack_interactivity], Inbound[:slack_events]. Inbound[:slack] is NOT registered.
```

Registration is already flat (`Inbound.register(name, Endpoint.new(…))`), so nesting is purely a
declaration-time fan-out: one `inbound` call producing N `Endpoint`s. No `Endpoint` or `Router`
changes.

Three semantics, settled:

1. **Name is `:"#{parent}_#{child}"`.** Letting the child name stand alone (`Inbound[:events]`) is
   shorter but collides across vendors — two vendors both wanting `:events`. A `separator:` or `as:`
   escape hatch is **punted**: unclear where `separator:` would live to read clearly, and unclear
   whether `as:` would name the child or override the parent prefix.
2. **A parent with `endpoint` blocks cannot itself register.** Mixing a top-level `dispatch` with
   `endpoint` blocks raises `ArgumentError` at declaration time. The alternative (parent registers
   *and* children register) silently produces a third endpoint nobody mounted.
3. **Children inherit everything and override by re-declaring** — `verify`, `challenge`,
   `challenge_required`, `unauthorized_headers`, `dispatch`, `respond`, `static_respond`, uniformly
   rather than as a curated subset.

**Implementation: copy the parent DSL's captured ivars into each child's fresh DSL, then
`instance_exec` the child block.** Not the ticket's suggested "re-`instance_exec` the parent block
per child" — replaying the parent block would re-run any side effects in it and would re-enter
`endpoint` recursively. `endpoint` inside `endpoint` raises; one level only.

The existing DSL validation (`__verifier__`'s "declared no `verify`" check, and the `mode: :async`
+ `respond` rejection) runs per child, unchanged — each child is a complete, independently valid
endpoint by the time it registers.

## Testing

Per item, following the repo's TDD rule (failing test first):

* **Config** — reads of every setting after freeze (the `FrozenError`-on-read regression this
  design exists to avoid), mutation rejected, unknown-event raise preserved, and an end-to-end
  `emit` against a frozen config.
* **`failed_count`** — sync path with a failing `Deliver`, asserting `failed_count` and that the
  result stays `ok`; async path asserting `0`.
* **`sign :hmac`** — each option's effect on the emitted headers, template rendering, the boot-time
  validations, and a round-trip integration spec against `verify :hmac` (mirroring the existing
  `outbound/integration_spec.rb` for `:standard_webhooks`).
* **Per-emit overrides** — `to:` replacing (not merging with) declared targets, one-off URL
  validation, `async: true` with no adapter raising, `async: false` suppressing the warning.
* **Nested inbound** — registered names, inheritance, child override, the mixed-declaration
  `ArgumentError`, and nested-`endpoint` rejection.

## Out of scope

Per-subscriber signing/auth, per-destination headers, SSRF allowlist, `webhook_id`→URL correlation,
and subscriber identity in `Deliver` — all [PRO-3214](https://linear.app/teamshares/issue/PRO-3214).
