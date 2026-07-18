# axn-webhooks — inbound HTTP webhook handler (design)

> **Source:** [PRO-2947 — [Axn] Webhook handler (inbound HTTP)](https://linear.app/teamshares/issue/PRO-2947/axn-webhook-handler-inbound-http). Brainstorm settled 2026-07-17; this document captures that settled design verbatim (lightly cleaned) as the spec the implementation plan is built from.

## Amendment — Phase 2 public API (settled 2026-07-18)

The ticket's `Axn::Webhooks.configure do |c| c.verifier :merge, … end` was **illustrative**. The settled public API is **block-per-endpoint** (grouped by vendor, not by concern):

```ruby
# config/initializers/webhooks.rb — declared centrally at a known boot point.
# The symbol passed to `inbound` is the vendor's name (whatever you reference it by).
Axn::Webhooks.inbound :codat do              # Codat — Standard Webhooks (Svix) preset
  verify :standard_webhooks, secret: ENV.fetch("CODAT_WEBHOOK_SECRET")
end

Axn::Webhooks.inbound :merge_dev do          # Merge (merge.dev) — parametric HMAC
  verify :hmac,
    secret:    ENV.fetch("MERGE_WEBHOOK_SIGNATURE_KEY"),   # boot-time (fail-fast); a lambda defers to request time
    signature: header("X-Merge-Webhook-Signature"),         # request resolver
    encoding:  :base64_urlsafe
  # later phases add dispatch / challenge / respond to the SAME block
end

Axn::Webhooks.inbound :twilio do             # Twilio — custom verifier delegating to the vendor SDK
  verify { |req| Twilio::Security::RequestValidator.new(ENV.fetch("TWILIO_AUTH_TOKEN"))
                   .validate(req.url, req.params, req.header("X-Twilio-Signature")) }
end
```

- **`Axn::Webhooks.inbound(:vendor) { … }`** (a top-level method) registers an endpoint; **`Axn::Webhooks::Inbound[:vendor]`** looks it up. Not nested inside `configure` — axn's `Configurable` owns `configure`/`config` for scalar settings (e.g. `vendor_facet`); endpoint registration is a separate concern.
- **Rationale for block-per-endpoint (Shape A) over the flat `c.verifier`/`c.dispatch` registries (Shape B):** all four declarations for a vendor co-locate, so onboarding/changing a vendor is one contiguous edit; B groups by concern (verifiers together — marginally better for a crypto audit, recoverable in A via `grep 'verify '`) but scatters each vendor across three lists. Deterministic registration at boot (no autoload dependency) — works identically in and out of Rails.
- **Secrets:** boot-time `ENV.fetch(...)` (fail-fast if missing); a `-> { … }` lambda is accepted anywhere a value must be resolved dynamically (incl. per-request).
- **Triggering is orthogonal** (Phase 5): Rails `mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"`; non-Rails `map "/webhooks/codat" { run Axn::Webhooks::Inbound[:codat] }` in a `Rack::Builder`. Both consume the same `Inbound[:vendor]` Rack app.
- Testable without HTTP: `Axn::Webhooks::Inbound[:codat].verify(request) # => Axn::Result`. Each endpoint compiles to a verify→dispatch→respond **Axn pipeline** internally ("internals are Axns").

## Amendment — Phase 3 dispatch (settled 2026-07-18)

Refines the ticket's "Dispatch" section into the built design:

- **`Endpoint#handle(request)`** is the full pipeline: `verify → parse body into event → route to handler Axn → Result`. `verify(request)` stays for verify-only testing. (Named `handle`, not `call` — Phase 5's Rack mount owns `call(env)`.)
- **Body → `event`:** defaults to `JSON.parse(raw_body)`; a per-endpoint `parse:` override handles other bodies (`parse: ->(req){ req.params }` for Twilio's form body, or a custom proc). Verify still runs on raw bytes *before* any parse. `on:`/`to:`/`with:` and the handler's `event:` all receive the parsed value.
- **Dispatch is an Axn**, so every "loud" failure is raised *inside* the axn boundary → axn's exception bucket → global `on_exception` (Honeybadger) + a formatted `result.error`; nothing escapes as an unhandled exception. Loud cases: **missing/unresolvable handler class**, and an **unmatched dispatch key when no `otherwise:` is declared** (an unexpected event type should page, not be swallowed).
- **`otherwise:`** accepts `:ack` (log + success, 2xx) or a **user callable** (a proc — e.g. send a Slack alert). `:notify` is dropped: that's a user decision, expressible as a proc.
- **Staged outcomes (verify+dispatch rows):** verify mismatch → failure (401); missing handler / unmatched-no-`otherwise` → exception (5xx, reported **once**, via `Handler.call!` inside `Dispatch`); handler business `fail!` → failure (2xx + log); handler crash → exception (5xx, reported); `otherwise: :ack` → success (2xx). HTTP mapping itself lands in Phase 4/5.
- **Handler args:** default `{ event: event }`; a map entry `{ call: "Handler", with: ->(e){ … } }` supplies scalar kwargs for a reused domain axn.
- **Sync this phase.** The `mode: :async` seam (Phase 4) delegates to the handler's `.call_async` and inherits whatever axn async adapter the app configured — designed against axn's async interface, never branching on `:sidekiq`/`:active_job`. See [[axn-webhooks-async-design]].

## Amendment — Phase 4 respond + async (settled 2026-07-18)

Refines the ticket's "### 4. Respond + staged outcome model":

- **`Axn::Webhooks::Response`** — a Rails-agnostic value (status/body/headers) with `.ack`/`.text`/`.xml` factories. Phase 5's Rack mount renders it. The `respond { |result| … }` DSL block runs with `ack`/`text`/`xml` as bare calls.
- **`Endpoint#to_response(request) → Response`** (named `to_response`, not `respond`, to avoid clashing with the `respond` DSL verb) is the staged HTTP mapper. Verify and dispatch are mapped in **separate branches** (stage-aware), because a verify failure (401) and a handler `fail!` (2xx) are both `outcome.failure?`. Table: verify mismatch/crash → 401; missing/unmatched handler, parse error, handler crash → 500 (reported); `otherwise: :ack` and handler `fail!` → bare 2xx; genuine handler success → the `respond` body (default bare ack). **`respond` fires only on a genuine handler success.**
- **Dynamic async `mode:`** (supersedes the ticket's "async is the default"; see [[axn-webhooks-async-design]]): `dispatch mode:` defaults to `:auto` — resolves to **async when an axn async adapter is configured for the resolved handler, else sync**; a custom `respond` forces sync; explicit `:sync`/`:async` override. Delegates to `handler.call_async` (adapter-agnostic; presence-detected, never type-branched). Explicit `mode: :async` + custom `respond` → boot-time error. Sync-vs-async is resolved inside `Dispatch` (per resolved handler).

## Amendment — Phase 5 Rack mount + challenge + vendor facet (settled 2026-07-18)

Realizes Packaging (mount-first), the Challenge section, and Decision 7:

- **`Endpoint#call(env)` is the Rack app** — `Inbound[:vendor]` mounts directly (`mount Inbound[:vendor], at: "/webhooks/vendor"` in Rails; `map … { run Inbound[:vendor] }` in a bare `Rack::Builder`). `Request.from_rack(env)` builds a `Request` from the env with pristine `rack.input` bytes (wrapped in a small `BuildRequest` axn so a malformed env is reported, not raised). `Response#to_rack` renders `[status, headers, [body]]` (keys already lowercased for Rack 3). POST → `to_response`; GET → `challenge_response`; other verbs → 405.
- **`challenge` DSL** — `challenge ->(req){ … }` (+ optional `if:` guard; note `if:` shadows the `if` keyword → read via `binding.local_variable_get(:if)`). Built as a `Challenge` axn exposing a typed `Response`. Statuses: **200** echo (text/plain); **403** guard/`if:` fail (Meta `hub.verify_token` convention); **400** resolver returns nil; **405** no `challenge` declared / non-GET-POST verb; **500** resolver/guard raises (reported). Slack's `url_verification` is a dispatch entry, not this.
- **`vendor_facet` setting** (`false` default / `:dimension` / `:tag`, via `Axn::Configurable`) — `Verify`/`Dispatch`/`Respond`/`Challenge` `include VendorFacet`, which declares BOTH `dimension :vendor` and `tag :vendor` with resolvers that read the **live** setting per-call (verified: axn omits a facet whose resolver returns nil), so exactly the selected facet (or none) is stamped. `Endpoint` threads `vendor: @name` into every pipeline call. Ships `false`; Teamshares sets `:dimension`.

## Spec-local notes (not in the ticket)

- **Scope of this repo = the library only.** The per-vendor rows in "Per-vendor migration" describe changes that land in the consuming apps (*os-app*, *buyout*) — separate follow-up work in other repos. Here we build the `axn-webhooks` gem and prove it with its own standalone test suite (no Rails required).
- **Build order (chosen): bottom-up layers.** Each layer is unit-tested in isolation before the next; the security-critical crypto lands first and hardest-tested; the full HTTP integration comes last.
  1. `Request` wrapper + `Axn::Webhooks::Signature.hmac` (crypto core)
  2. verifier registry + `verify` DSL + `:standard_webhooks` preset + custom/SDK slot
  3. `dispatch` DSL (`to` / `on` / `with` / `via` / `otherwise`)
  4. `respond` + staged outcome model (the Axn pipeline: verify → dispatch → respond)
  5. Rack mount + `Inbound[:vendor]` + `challenge` GET branch + auto-`dimension`

---

## Goal

One reusable library that DRYs the inbound-webhook pattern shared across os-app (Codat, Merge, Lob, ModernTreasury, Slack, DropboxSign, internal) and buyout (Twilio, Nylas): **verify signature → parse → dispatch to a handler Axn → ack.** Shippable as a **standalone/public gem,** `axn-webhooks`, whose only real dependency is `axn` (the `axn-*` family base) + Rack — no teamshares-rails or `ApplicationController`. The gem name is a deliberate **bidirectional umbrella**: this ticket builds the **inbound** half; the **outbound** half (existing `send_webhook` actions) is a reserved future sibling that shares the signing primitive (see Decisions).

## Adapter boundary (vs [PRO-2936 `axn-openapi`](https://linear.app/teamshares/issue/PRO-2936/axn-axn-openapi))

The line is **who owns the contract**, not whether the response body is meaningful:

* **This adapter (webhook):** a vendor calls *us* on *the vendor's* contract; we verify their signature and react. The response is whatever that vendor demands — a bare ack, a literal string (DropboxSign), or an instruction body (Twilio TwiML). All inbound vendor hooks live here.
* **`axn-openapi` ([PRO-2936](https://linear.app/teamshares/issue/PRO-2936/axn-axn-openapi)):** *we* own and publish the contract (typed request/response + an OpenAPI doc for arbitrary clients).

By that line, **all eight vendors below fit this one adapter** — including Twilio TwiML. Nothing spills into [PRO-2936](https://linear.app/teamshares/issue/PRO-2936/axn-axn-openapi).

## Current state

**The shared base (`TS::Webhooks::BaseController`) buys almost nothing.** It's just (a) inherit `ActionController::Base` directly so the app's Devise/Pundit/CSRF filters don't attach, and (b) a `validate_incoming_hook! → incoming_request_valid? → rescue 401` template. That's *config-shaped, not inheritance-shaped* — and inheriting a `TS::` class is what chains it to teamshares-rails.

**Every vendor's verification is HMAC** (surveyed):

| Vendor | digest | signs | encoding | sig location | replay | const-time compare? |
| -- | -- | -- | -- | -- | -- | -- |
| Merge | sha256 | raw body | base64-urlsafe | `X-Merge-Webhook-Signature` | — | ✅ |
| Lob | sha256 | `ts.body` | hex | `Lob-Signature` | 5 min | ❌ `==` |
| Codat (Svix) | sha256 | `id.ts.body` | base64 | `svix-signature` | ±tolerance | (svix gem) |
| ModernTreasury | sha256 | raw body | hex | `X-Signature` | — | ❌ `==` |
| Slack | sha256 | `v0:ts:body` | hex (`v0=`) | `X-Slack-Signature` | 5 min | ✅ |
| DropboxSign | md5 + sha256 | `json` / `event_time+event_type` | base64 | `Content-MD5` hdr + `event_hash` in body | — | ❌ `==` |
| Nylas | sha256 | raw body | hex | `X-Nylas-Signature` | — | (bespoke processor) |
| Twilio | **sha1** | **URL + sorted params** | base64 | `X-Twilio-Signature` | — | (not used today — see below) |

Findings: (1) all are HMAC differing only along a small axis set → a **single parametric HMAC** covers most; (2) **3 of 6** os-app verifiers use plain `==` instead of constant-time compare → a real **timing-attack surface** a shared verifier fixes in one place; (3) Nylas hand-rolls its own `secure_compare` inside a bespoke processor; (4) Twilio's live auth is **HTTP Basic** (a Teamshares hack), *not* its real `X-Twilio-Signature` contract.

**Response requirements (grounded in upstream docs):**

| Vendor | Upstream actually requires | Today's code | Verdict |
| -- | -- | -- | -- |
| DropboxSign | 200 **+ literal** `"Hello API Event Received"` | renders that string | ✅ real requirement |
| Twilio (call/SMS) | **TwiML** body (instruction) | `render xml:` (in `initiate`) | ✅ real requirement |
| Twilio (status cb) | empty 200 | mixed | should be bare ack |
| Merge | any 2xx, fast, work async | `render plain: result.message` (sync) | ❌ drift (+ violates async guidance) |
| Lob | any 2xx, **body ignored** | `render plain: "OK"`, **422 on failure** | ❌ drift + **bug** (422 → retry storm → endpoint disabled after 5 days) |
| everything else | 2xx ack | `head :ok` | ✅ |

So the correct **default is a bare 2xx ack, work async**; the response-formatter seam is needed for exactly two real cases (DropboxSign literal, Twilio TwiML).

## Design — the DSL

Four composable declarations (`verify` / `dispatch` / `challenge` / `respond`); a vendor uses only what it needs. Core = Axns (see "Internals are Axns") operating on a thin `Request` wrapper (`raw_body`, `header(name)`, `params`, `url`) so it's Rails-agnostic.

### 1. Verify — parametric HMAC + a registry for presets/custom/SDK strategies

The HMAC primitive lives in the **shared** `Axn::Webhooks::Signature` module (inbound `verify` and future outbound `sign` are the two faces of it):

```ruby
Axn::Webhooks::Signature.hmac(
  secret:,
  digest:         :sha256,               # default
  signing_string: ->(r){ r.raw_body },   # default = raw body
  encoding:       :hex,                   # :hex | :base64 | :base64_urlsafe
  prefix:         nil,                    # e.g. "v0="
  signature:      header("X-Signature"),
  replay:         nil,                    # { timestamp: header("..."), within: 5.minutes }
)
# ALWAYS constant-time compare; supports multi-sig headers (key rotation) — pass if any candidate matches
```

* **Default general strategy =** `:hmac` (parametric). Covers Merge/Lob/MT/Slack/Nylas as ~2–5 lines of config each.
* `:standard_webhooks` **preset** = the Svix scheme (adds: `whsec_`-strip + base64-decode secret, per-candidate `v1,` version handling, **bidirectional** ±tolerance). Confirmed a real cross-industry spec (OpenAI, Anthropic, Supabase; committee incl. Svix/Ngrok/Zapier/Twilio/Lob). **Drop the `svix` gem** — it's a huge generated API SDK; we use only its ~50-line `Webhook#verify`. Not the universal default (inbound third parties don't comply), but the **recommended default for our *own* hooks** — today's `InternalBaseController` (currently `ActiveSupport::MessageVerifier`) and outbound `send_webhook`.
* **SDK-delegating custom verifiers** are first-class: for Twilio, delegate to `Twilio::Security::RequestValidator` rather than reimplement its URL+params SHA1 scheme. Same registry slot as any custom lambda.
* **Registry lives in an initializer** — one auditable crypto/secrets surface:

```ruby
# config/initializers/webhooks.rb
Axn::Webhooks.configure do |c|
  c.verifier :merge, :hmac, secret: ENV["MERGE_WEBHOOK_SIGNATURE_KEY"], signature: header("X-Merge-Webhook-Signature"), encoding: :base64_urlsafe
  c.verifier :codat, :standard_webhooks, secret: ENV["CODAT_WEBHOOK_SECRET"]
  c.verifier :twilio do |req|                        # SDK-delegating
    Twilio::Security::RequestValidator.new(ENV["TWILIO_AUTH_TOKEN"]).validate(req.url, req.params, req.header("X-Twilio-Signature"))
  end
  c.verifier :dropbox_sign do |req| … end            # fully custom dual-check
end
```

### 2. Dispatch — key from endpoint *or* body field

```ruby
dispatch to: "Actions::Lob::HandleWebhook"                       # one endpoint = one handler
dispatch on: ->(e){ e[:eventType] },                            # key from a body field (explicit map)
         to: { "connection.updated" => "Actions::Codat::Webhook::ConnectionUpdated", … },
         otherwise: :ack                                         # unknown-but-expected → log + 2xx (or :notify)
dispatch on: ->(e){ [e.dig("data","object"), e["event"]] }, to: { … }   # tuple key (ModernTreasury)
dispatch on: ->(e){ e[:eventType] }, to: "Actions::Codat::Webhook", via: ->(k){ k.tr(".","_").camelize }  # convention sugar
```

* **Explicit map is the baseline** (greppable; avoids the `const_get` fragility that produced the queue's alias shims in [PRO-2938](https://linear.app/teamshares/issue/PRO-2938/axn-inbound-queue-adapter-snssqs-message-bus)). **Convention sugar:** pass a **String namespace** to `to:` to derive the class from the dispatch key (default transform `key.tr(".","_").camelize`, override with `via:`). Tradeoff: convention **can't boot-validate the vendor's event vocabulary**, so its safety net is a loud runtime miss (see below) + `otherwise:`; use it where the name mapping is clean (Codat, Slack), keep explicit where auditability matters.
* **Verify and parse are separated** (today `incoming_request_valid?` side-effects `@data`). Verify against **raw bytes before any parser touches them** (Nylas docs stress this; the Rack mount gives this for free — see Packaging).
* **Payload → handler arguments** — two handler realities, each served cleanly (no source-branching inside any axn):
  * **Webhook-native handlers** get the whole parsed body as one `event:` kwarg (raw parsed Hash — **no normalization needed**, because Axn's `on:` subfields are indifferent to string vs symbol keys) and destructure with Axn's `on:` subfield resolver — the idiomatic form of "typed payload → `expects` via coercion," declared by the handler, not library magic:

    ```ruby
    expects :event, type: Hash
    expects :connection, on: "event.payload.connection"
    expects :id, :sourceType, on: :connection
    ```
  * **Reused domain axns** stay pristine (their existing scalar signature, e.g. `expects :payment_order_id`); the webhook layer adapts via a `with:` **extractor proc** in the dispatch entry. It runs sync at dispatch time (cheap extraction from the verified payload) then enqueues clean scalars, so it composes with `mode: :async`:

    ```ruby
    to: { ["payment_order","reconciled"] => {
            call: "ModernTreasury::PaymentOrder::DispatchCompleted",
            with: ->(e){ { payment_order_id: e.dig(:data, :id) } } } }
    ```
* **Sync vs async —** `mode: :async` **is the default** (ack fast, run the handler on Sidekiq). A **result-reading** `respond` **implies** `:sync` (can't render a result-derived body without waiting). Only Twilio call-control needs sync; everything else acks fast. Both modes are Sidekiq-safe (payload args are JSON-simple).

### 3. Challenge — optional GET-echo handshake

Grounded survey: GET-echo family (Nylas `?challenge=`, Meta `?hub.challenge=` + token) is DRY-able; Slack's `url_verification` is an in-band POST (rides **dispatch**, not this feature); Zoom's is a crypto response (proc). Ship the common case, off by default:

```ruby
challenge ->(req){ req.params["challenge"] }                                # Nylas — echo verbatim, 200
challenge ->(req){ req.params["hub.challenge"] },
          if: ->(req){ req.params["hub.verify_token"] == ENV["META_VERIFY_TOKEN"] }   # Meta
```

* **The mount owns the whole path, every verb**, so `challenge` just installs the endpoint's `GET` branch internally — **no extra `routes.rb` line.** `GET …?challenge=X` → echo `X` (200 plain); `POST` → verify/dispatch/respond; `GET` with no `challenge` declared → 405.
* **Slack's `url_verification` does NOT use this** — it's an in-band POST event handled as a sync dispatch entry (`"url_verification" => ->(e){ e[:challenge] }`) with a plain response.

### 4. Respond + staged outcome model

Response and error-reporting are **staged** — each stage is an Axn, and the HTTP mapping + `on_exception` behavior read straight off each Result (see "Internals are Axns"):

| Stage | outcome | HTTP | `on_exception` (Honeybadger)? |
| -- | -- | -- | -- |
| Verify | signature mismatch → `fail!` | **401** | no (forged/noisy requests shouldn't page) |
| Verify | verifier *crashes* (bad header, crypto raise) → exception | 401 | yes (real bug; still 401 externally so we don't leak) |
| Dispatch | unknown-but-expected event (`otherwise: :ack`) | **2xx** | no |
| Dispatch | handler class missing/unresolvable → exception | **5xx** | **yes** |
| Handle | business `fail!` ("we don't care") | **2xx** + log | no |
| Handle | unexpected exception | **5xx** | **yes** |

* Axn's failure-vs-exception distinction **is** the "loud vs quiet" control: a plain signature mismatch stays quiet (401, no page); a missing handler or handler crash is loud (5xx + on_exception).
* **Missing-handler = exception, deliberately:** 5xx → vendor retries within its window (a deploy-grace period so the event isn't lost) **and** Honeybadger fires — strictly better than today's silent `const_get`→shim. Caveat: retry-storm risk if never fixed, acceptable because it's paging the whole time.
* This **fixes Lob's 422-on-failure bug** and the widespread unconditional-`head :ok` swallowing.

```ruby
respond ->(r){ head :ok }                              # default — most vendors
respond ->(_){ render plain: "Hello API Event Received" }   # DropboxSign (real requirement)
respond ->(r){ render xml: r.twiml }                   # Twilio call-control (handler computes TwiML; forces sync)
```

## Internals are Axns (observability + error handling for free)

Build the pipeline (verify → dispatch → respond) as Axns and dogfood the framework:

* **Error reporting for free:** a miss just `raise`s → Axn's exception bucket → the consuming app's `Axn.config.on_exception` (Honeybadger at Teamshares). No hand-rolled `Honeybadger.notify` in the gem; the staged table above is just Axn's native failure-vs-exception semantics.
* **Metrics/OTel for free (ties to [PRO-2818](https://linear.app/teamshares/issue/PRO-2818/axn-datadog-observability-axn-overview-dashboard)):** Axn emits metrics + OTel spans + structured logs per call, so the whole webhook pipeline is observable with no extra code, and the pipeline is testable as ordinary axns.
* **Config-driven vendor facet:** governed by `setting :vendor_facet` (default `false`; `:dimension` | `:tag`). When enabled, the adapter stamps the registry name onto the pipeline as that facet from the mount/definition name, with **zero per-handler boilerplate** — `:dimension` gives a bounded low-cardinality facet ideal for grouping/filtering Datadog metrics + traces + exception reports by vendor (vendor is a small known set); `:tag` is available for the higher-cardinality path. Ships `false`; Teamshares sets `:dimension`.

## Packaging

Core = Axns (verifier + dispatcher + ack mapper + Request wrapper), depends on `axn` + Rack, not ActionController/ts-r. **Decision: default to the Rack mount; only reach for the controller concern if the mount doesn't cleanly cover a case.**

* **Mountable Rack endpoint (default)** — `mount Axn::Webhooks::Inbound[:codat], at: "/webhooks/codat"`; **routes.rb becomes the single greppable registry** of every webhook. Bonus correctness: a mount **bypasses ActionController param parsing**, so `rack.input` is the pristine raw body — exactly what signature verification needs. A controller sometimes fights Rails having already parsed/re-serialized.
* **Controller concern (reserve)** — same declarations, for any case the mount can't cover. To be confirmed none is forced.

## Per-vendor migration (all fit) — *lands in consuming apps, not this repo*

| Vendor | verify | dispatch | challenge | respond |
| -- | -- | -- | -- | -- |
| Codat | `:standard_webhooks` | by field (`eventType`) | — | ack |
| Merge | `:hmac` base64-urlsafe | by endpoint (3 routes) | — | ack (drop `result.message`; make async) |
| Lob | `:hmac` `ts.body` + replay | by endpoint | — | ack (**fix 422 bug**) |
| ModernTreasury | `:hmac` raw body | by field (tuple) | — | ack |
| Slack | `:hmac` `v0:ts:body` + `v0=` + replay | by field (incl. `url_verification`) | — | ack |
| DropboxSign | custom dual-check | subclass → by field | — | literal string |
| Nylas | `:hmac` raw body hex | by field | **GET echo** | ack (delete bespoke processor) |
| Twilio | custom → `RequestValidator` | by endpoint/action | — | TwiML (call, sync), ack (status cb); replace Basic-auth hack |

Also migrate `InternalApiController` (via `InternalBaseController`) to `:standard_webhooks`.

## Decisions

1. **Preset name =** `:standard_webhooks` (accurate; confirmed real cross-industry spec).
2. **Packaging = mount-first**; controller concern only if the mount can't cover a case.
3. **Challenge = a GET branch the mount owns internally** (no extra routing); Slack's handshake is a dispatch entry, not `challenge`.
4. **Dispatch mode = async by default**; a result-reading `respond` forces sync (Twilio only).
5. **Payload → handler:** pass the raw parsed body as `event:`; webhook-native handlers destructure with Axn `on:` subfields (indifferent to key casing); reused domain axns stay scalar and get a `with:` extractor proc at the dispatch boundary. Dispatch `to:` accepts an explicit map (baseline) or a namespace String for name-from-event convention (`via:` override + loud miss).
6. **Internals built as Axns** → `on_exception`/Honeybadger, metrics, OTel spans, structured logs for free; staged outcome model = Axn's native failure-vs-exception semantics.
7. **Vendor facet is a config setting** (amended 2026-07-17): `setting :vendor_facet, default: false, one_of: [false, :dimension, :tag]`, declared via axn's `Axn::Configurable` (`config_namespace :webhooks`, as in sibling gems `axn-mcp`/`axn-ruby_llm`). When set, the adapter stamps the registry name onto the pipeline as that facet (`:dimension` → `dimension :vendor, <name>` for per-vendor observability grouping, ties to [PRO-2818](https://linear.app/teamshares/issue/PRO-2818/axn-datadog-observability-axn-overview-dashboard); `:tag` for the higher-cardinality path). Ships `false` so a standalone consumer opts in; **Teamshares usage sets `:dimension`.** (Supersedes the original "auto-`dimension`, zero-config" phrasing.)
8. **Gem =** `axn-webhooks` (bidirectional umbrella). Namespace: `Axn::Webhooks::Inbound` for this work (registry `Axn::Webhooks.configure` / lookup `Axn::Webhooks::Inbound[:vendor]` → one endpoint), `Axn::Webhooks::Outbound` reserved for a future sibling (the existing `send_webhook` actions), and a shared `Axn::Webhooks::Signature` primitive that both `verify` (in) and `sign` (out) build on. Build inbound only now; outbound is a grounded reservation, not a commitment. Rejected `webhook_handler` (breaks the `axn-*` family, generic/collision-prone) and inbound-only names like `axn-webhook-receiver` (would duplicate the signing primitive or need a third shared gem).

## Open questions

None blocking — ready for an implementation plan. (Confirm during build: that no vendor forces the controller concern over the mount.)

## Related

* Split sibling: [PRO-2938](https://linear.app/teamshares/issue/PRO-2938/axn-inbound-queue-adapter-snssqs-message-bus) (SNS→SQS queue). Shared surface is minimal (an ack *principle*); extract a tiny dispatch/ack helper only if it falls out emergently — not a design-time dependency.
* Future sibling (same gem): **outbound webhooks** — migrate teamshares-rails `send_webhook` / `send_webhook_to_specific_subscriber` onto `Axn::Webhooks::Outbound`, reusing `Axn::Webhooks::Signature` (and adopting `:standard_webhooks` for our own emitted hooks).
* Observability: [PRO-2818](https://linear.app/teamshares/issue/PRO-2818/axn-datadog-observability-axn-overview-dashboard) (Datadog) — the auto-`dimension` + Axn metrics/OTel feed directly into it.
* Close cousin: the Slack interactivity adapter (also inbound-dispatch; its signature verification reuses this verifier).

## Sources

DropboxSign walkthrough; Merge best-practices; Lob webhooks; Nylas verify-signatures + notifications; Twilio webhooks-security + FAQ; [standardwebhooks.com](https://standardwebhooks.com) (adoption).
