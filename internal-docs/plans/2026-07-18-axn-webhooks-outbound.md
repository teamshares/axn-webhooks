# axn-webhooks Outbound Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the outbound half of `axn-webhooks` — a `Axn::Webhooks.outbound` declaration DSL + `Axn::Webhooks.emit` that fan-out one signed, self-retrying delivery per subscriber — reusing the existing shared `Axn::Webhooks::Signature`, plus a small inbound `retry_later!` affordance.

**Architecture:** A single process-global `Outbound` registry (populated by one `Axn::Webhooks.outbound do … end` block) holds the signer, the subscriber resolver, the event→targets map, and the retry curve. `Axn::Webhooks.emit(:event, data:)` runs the `Emit` axn (loud on unknown events), which builds a Standard-Webhooks envelope and enqueues one `Deliver` axn per resolved target via `call_async`. `Deliver` is a self-managed retry engine: it signs per-attempt (fresh timestamp, stable `webhook-id`), POSTs via an injectable `Transport`, classifies the response, and either succeeds, quietly fails (permanent 4xx), or reschedules itself via axn's adapter-agnostic `call_async(_async: { wait: })` seam (honoring `Retry-After`). Every stage is an Axn, so metrics/OTel/`on_exception` come free.

**Tech Stack:** Ruby ≥ 3.2.1, `axn`, `rack` (existing deps), Ruby stdlib `net/http` + `securerandom` + `json` (no new runtime dependency), RSpec.

## Global Constraints

- **No new runtime gem dependency.** HTTP uses stdlib `net/http`; the transport is injectable so a consuming app may swap in Faraday. Gemspec deps stay `axn` + `rack` only.
- **Works outside Rails.** Guard any `Rails`/`ActiveRecord`/`ActiveJob` reference with `defined?(...)`. The gem's own suite (`spec/`) runs Rails-free.
- **TDD.** Failing test first, minimal implementation, then green. Frequent commits (one per task).
- **`bundle exec rake`** (specs + rubocop) must pass before a task is considered done.
- **Never branch on async adapter TYPE** (`:sidekiq`/`:active_job`). Delegate to axn's `call_async` / `_async` interface. See the inbound `Dispatch` for the established pattern.
- **Secrets never enter the job payload.** `Deliver` reads the secret from `Outbound.config` at runtime, never as a `call_async` kwarg.
- **CHANGELOG** every user-visible change under `## [Unreleased]`.
- **Namespace:** everything lives under `Axn::Webhooks::Outbound` (+ the `Axn::Webhooks.outbound`/`.emit` module methods), reusing `Axn::Webhooks::Signature`.

---

## File Structure

- `lib/axn/webhooks/outbound.rb` — the `Outbound` registry module, `Axn::Webhooks.outbound` entry point, `Axn::Webhooks.emit` delegator, `Outbound.config`/`reset!`, and the local `Axn::Webhooks.swallow_soft_error` shim.
- `lib/axn/webhooks/outbound/dsl.rb` — `Outbound::DSL`, the receiver for the `outbound` block (`sign`/`subscribers`/`event`/`max_attempts`/`backoff`).
- `lib/axn/webhooks/outbound/config.rb` — `Outbound::Config`, the resolved immutable declaration + subscriber resolution + event lookup.
- `lib/axn/webhooks/outbound/signer.rb` — `Outbound::Signer`, builds the signed header hash for `(id, timestamp, body)` (`:standard_webhooks` default + custom block).
- `lib/axn/webhooks/outbound/envelope.rb` — `Outbound::Envelope`, builds the `{id,timestamp,type,data}` body + `webhook-id` generation.
- `lib/axn/webhooks/outbound/transport.rb` — `Outbound::Transport` (stdlib `net/http` POST) + `Transport::Response` value; the retryable-network-error set.
- `lib/axn/webhooks/outbound/emit.rb` — `Outbound::Emit` axn (validate event, resolve targets, fan out).
- `lib/axn/webhooks/outbound/deliver.rb` — `Outbound::Deliver` axn (the per-attempt delivery + self-managed retry engine).
- Inbound changes: `lib/axn/webhooks/errors.rb` (new `RetryLater` + `retry_later!`), `lib/axn/webhooks/response.rb` (`.service_unavailable`), `lib/axn/webhooks/dispatch.rb` (rescue `RetryLater`), `lib/axn/webhooks/inbound/endpoint.rb` (`retry_after` → 503).
- Wiring: `lib/axn/webhooks.rb` (requires); `README.md`, `CHANGELOG.md`.
- Tests mirror under `spec/axn/webhooks/outbound/…` and existing inbound spec files.

---

### Task 1: Outbound Signer (`:standard_webhooks` + custom block)

Signs `(id, timestamp, body)` into a header hash, reusing `Signature.compute` and the existing `Verifiers::StandardWebhooks.decode_secret`. This is the outbound face of the shared signing primitive.

**Files:**
- Create: `lib/axn/webhooks/outbound/signer.rb`
- Test: `spec/axn/webhooks/outbound/signer_spec.rb`

**Interfaces:**
- Consumes: `Axn::Webhooks::Signature.compute(secret:, payload:, digest:, encoding:)`; `Axn::Webhooks::Verifiers::StandardWebhooks.decode_secret(secret)`.
- Produces: `Axn::Webhooks::Outbound::Signer.build(spec)` → an object responding to `#call(id:, timestamp:, body:) → Hash{String=>String}`. `spec` is `{ strategy:, opts:, block: }` (same shape as the verify spec). The SW signer returns keys `"webhook-id"`, `"webhook-timestamp"`, `"webhook-signature"` (value `"v1,<base64>"`). A custom block is called verbatim and must return a header hash.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/outbound/signer_spec.rb
# frozen_string_literal: true

require "base64"

RSpec.describe Axn::Webhooks::Outbound::Signer do
  # whsec_ + base64("secret") so decode_secret yields the raw "secret" bytes.
  let(:secret) { "whsec_#{Base64.strict_encode64('secret')}" }

  describe ":standard_webhooks strategy" do
    subject(:signer) { described_class.build(strategy: :standard_webhooks, opts: { secret: }, block: nil) }

    it "produces webhook-id / webhook-timestamp / v1 signature headers" do
      headers = signer.call(id: "msg_1", timestamp: 1_700_000_000, body: '{"a":1}')

      expect(headers["webhook-id"]).to eq("msg_1")
      expect(headers["webhook-timestamp"]).to eq("1700000000")
      expect(headers["webhook-signature"]).to start_with("v1,")
    end

    it "signs id.timestamp.body with the decoded secret so the inbound verifier accepts it" do
      id = "msg_1"
      ts = 1_700_000_000
      body = '{"a":1}'
      headers = signer.call(id:, timestamp: ts, body:)

      expected = Axn::Webhooks::Signature.compute(
        secret: "secret", payload: "#{id}.#{ts}.#{body}", digest: :sha256, encoding: :base64,
      )
      expect(headers["webhook-signature"]).to eq("v1,#{expected}")
    end
  end

  describe "custom block" do
    it "uses the block verbatim and returns its header hash" do
      signer = described_class.build(
        strategy: nil, opts: {},
        block: ->(id:, timestamp:, body:) { { "x-sig" => "#{id}:#{timestamp}:#{body.bytesize}" } },
      )
      expect(signer.call(id: "m", timestamp: 5, body: "abc")).to eq("x-sig" => "m:5:3")
    end
  end

  it "raises on an unknown strategy" do
    expect { described_class.build(strategy: :nope, opts: {}, block: nil) }
      .to raise_error(Axn::Webhooks::Error, /unknown sign strategy/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/signer_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Outbound` (or `::Signer`).

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/outbound/signer.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Builds a signer callable (#call(id:, timestamp:, body:) -> header Hash) from a `sign`
      # declaration. The :standard_webhooks strategy is the outbound face of the inbound
      # verify :standard_webhooks — same scheme, so a receiver using that verifier accepts it.
      module Signer
        module_function

        def build(strategy:, opts:, block:)
          return CustomSigner.new(block) if block

          case strategy&.to_sym
          when :standard_webhooks then StandardWebhooksSigner.new(**opts)
          else raise Axn::Webhooks::Error, "unknown sign strategy #{strategy.inspect}"
          end
        end

        # Wraps a user block; called with the same kwargs as the built-in signers.
        class CustomSigner
          def initialize(block) = @block = block
          def call(id:, timestamp:, body:) = @block.call(id:, timestamp:, body:)
        end

        # Standard Webhooks: secret is `whsec_<base64>`; sign `id.timestamp.body` (sha256/base64);
        # emit `v1,<sig>` alongside the id/timestamp headers the inbound verifier reads.
        class StandardWebhooksSigner
          def initialize(secret:)
            @secret = secret
          end

          def call(id:, timestamp:, body:)
            sig = Signature.compute(
              secret: Verifiers::StandardWebhooks.decode_secret(@secret),
              payload: "#{id}.#{timestamp}.#{body}",
              digest: :sha256,
              encoding: :base64,
            )
            {
              "webhook-id" => id.to_s,
              "webhook-timestamp" => timestamp.to_s,
              "webhook-signature" => "v1,#{sig}",
            }
          end
        end
      end
    end
  end
end
```

Add the require to `lib/axn/webhooks.rb` (after the existing `require_relative "webhooks/dispatch"` line):

```ruby
require_relative "webhooks/outbound/signer"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/signer_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/outbound/signer.rb spec/axn/webhooks/outbound/signer_spec.rb lib/axn/webhooks.rb
git commit -m "feat(outbound): Signer — standard_webhooks + custom-block signing headers"
```

---

### Task 2: Envelope builder

Builds the Standard-Webhooks body and generates the `webhook-id`. Kept separate from the signer so the (stable) body and the (per-attempt) signature are cleanly decoupled.

**Files:**
- Create: `lib/axn/webhooks/outbound/envelope.rb`
- Test: `spec/axn/webhooks/outbound/envelope_spec.rb`

**Interfaces:**
- Produces:
  - `Axn::Webhooks::Outbound::Envelope.new_id → String` (`"msg_<uuid>"`).
  - `Axn::Webhooks::Outbound::Envelope.build(id:, type:, data:, now:) → String` — JSON of `{"id","timestamp","type","data"}`; `timestamp` is `now.to_i`; `now` defaults to `Time.now` (injectable for tests).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/outbound/envelope_spec.rb
# frozen_string_literal: true

require "json"

RSpec.describe Axn::Webhooks::Outbound::Envelope do
  describe ".new_id" do
    it "is prefixed and unique" do
      a = described_class.new_id
      b = described_class.new_id
      expect(a).to start_with("msg_")
      expect(a).not_to eq(b)
    end
  end

  describe ".build" do
    it "produces the {id,timestamp,type,data} envelope as JSON" do
      json = described_class.build(id: "msg_1", type: "lead_signed",
                                   data: { "lead_id" => 42 }, now: Time.at(1_700_000_000))
      expect(JSON.parse(json)).to eq(
        "id" => "msg_1", "timestamp" => 1_700_000_000,
        "type" => "lead_signed", "data" => { "lead_id" => 42 },
      )
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/envelope_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Outbound::Envelope`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/outbound/envelope.rb
# frozen_string_literal: true

require "json"
require "securerandom"

module Axn
  module Webhooks
    module Outbound
      # Builds the Standard Webhooks message body and its idempotency id. The body is fixed at
      # emit time (part of the dedup identity); the SIGNATURE is recomputed per delivery attempt
      # (see Deliver), so this carries no signing concern.
      module Envelope
        module_function

        def new_id = "msg_#{SecureRandom.uuid}"

        def build(id:, type:, data:, now: Time.now)
          JSON.generate(id:, timestamp: now.to_i, type: type.to_s, data:)
        end
      end
    end
  end
end
```

Add to `lib/axn/webhooks.rb`:

```ruby
require_relative "webhooks/outbound/envelope"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/envelope_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/outbound/envelope.rb spec/axn/webhooks/outbound/envelope_spec.rb lib/axn/webhooks.rb
git commit -m "feat(outbound): Envelope — standard-webhooks body + webhook-id"
```

---

### Task 3: Transport (stdlib net/http) + Response value

The injectable HTTP seam. Default is stdlib `net/http` so the gem gains no runtime dependency; a consuming app may set its own transport (e.g. Faraday-backed) via config.

**Files:**
- Create: `lib/axn/webhooks/outbound/transport.rb`
- Test: `spec/axn/webhooks/outbound/transport_spec.rb`

**Interfaces:**
- Produces:
  - `Axn::Webhooks::Outbound::Transport::Response = Data.define(:status, :headers)` — `status` Integer, `headers` Hash.
  - `Axn::Webhooks::Outbound::Transport.post(url:, body:, headers:, open_timeout:, read_timeout:) → Transport::Response`. `open_timeout`/`read_timeout` default to 5/10 seconds.
  - `Axn::Webhooks::Outbound::Transport::RETRYABLE_NETWORK_ERRORS` — an Array of exception classes callers treat as retryable when raised by a transport.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/outbound/transport_spec.rb
# frozen_string_literal: true

require "webrick"

RSpec.describe Axn::Webhooks::Outbound::Transport do
  it "exposes a Data Response value" do
    resp = described_class::Response.new(status: 204, headers: { "x" => "y" })
    expect(resp.status).to eq(204)
    expect(resp.headers).to eq("x" => "y")
  end

  it "declares a retryable-network-error set including Timeout::Error" do
    expect(described_class::RETRYABLE_NETWORK_ERRORS).to include(Timeout::Error)
  end

  describe ".post (against a local server)" do
    let!(:server) do
      WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    end
    let(:port) { server.config[:Port] }
    let(:received) { {} }

    before do
      server.mount_proc("/hook") do |req, res|
        received[:body] = req.body
        received[:sig] = req["webhook-signature"]
        res.status = 202
        res["retry-after"] = "30"
      end
      @thread = Thread.new { server.start }
    end

    after do
      server.shutdown
      @thread&.join
    end

    it "POSTs the body + headers and returns status + response headers" do
      resp = described_class.post(
        url: "http://127.0.0.1:#{port}/hook",
        body: '{"a":1}',
        headers: { "content-type" => "application/json", "webhook-signature" => "v1,x" },
      )

      expect(resp.status).to eq(202)
      expect(resp.headers["retry-after"]).to eq("30")
      expect(received[:body]).to eq('{"a":1}')
      expect(received[:sig]).to eq("v1,x")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/transport_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Outbound::Transport`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/outbound/transport.rb
# frozen_string_literal: true

require "net/http"
require "uri"

module Axn
  module Webhooks
    module Outbound
      # The HTTP seam. Default is stdlib Net::HTTP (no runtime dependency); a consuming app may
      # inject its own object responding to `.post(url:, body:, headers:)` via Outbound config.
      module Transport
        Response = Data.define(:status, :headers)

        # Raised by a transport for a genuinely retryable network condition. Deliver treats these
        # (and 5xx/429/503) as retryable; anything else raised by a transport is an unexpected
        # exception that propagates (the adapter's at-least-once crash safety net).
        RETRYABLE_NETWORK_ERRORS = [
          Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
          Errno::ETIMEDOUT, SocketError, IOError
        ].freeze

        module_function

        def post(url:, body:, headers:, open_timeout: 5, read_timeout: 10)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout

          request = Net::HTTP::Post.new(uri.request_uri)
          request.body = body
          headers.each { |key, value| request[key] = value }

          response = http.request(request)
          Response.new(status: response.code.to_i, headers: response.to_hash.transform_values(&:first))
        end
      end
    end
  end
end
```

Add to `lib/axn/webhooks.rb`:

```ruby
require_relative "webhooks/outbound/transport"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/transport_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/outbound/transport.rb spec/axn/webhooks/outbound/transport_spec.rb lib/axn/webhooks.rb
git commit -m "feat(outbound): Transport — stdlib net/http POST + Response value"
```

---

### Task 4: Outbound registry, DSL, Config, and the soft-error shim

The declaration surface: `Axn::Webhooks.outbound do … end` populates a single process-global `Outbound::Config`; `Axn::Webhooks.emit` is stubbed here and wired in Task 6. Also adds the local `swallow_soft_error` shim (the temporary stand-in for the future promoted axn-core helper).

**Files:**
- Create: `lib/axn/webhooks/outbound/config.rb`, `lib/axn/webhooks/outbound/dsl.rb`, `lib/axn/webhooks/outbound.rb`
- Modify: `lib/axn/webhooks.rb`
- Test: `spec/axn/webhooks/outbound/dsl_spec.rb`

**Interfaces:**
- Consumes: `Outbound::Signer.build(...)` (Task 1).
- Produces:
  - `Axn::Webhooks.outbound(&block)` — evaluates the block in `Outbound::DSL`, stores an `Outbound::Config` as the process-global registration.
  - `Axn::Webhooks::Outbound.config → Outbound::Config` (raises `Axn::Webhooks::Error` if `outbound` was never declared); `Axn::Webhooks::Outbound.reset!`.
  - `Outbound::Config#signer → #call(id:,timestamp:,body:)`; `#max_attempts → Integer`; `#backoff → #call(Integer)`; `#targets_for(event) → Array<String>` (raises `Axn::Webhooks::Error` on an unknown event, listing known ones); `#wire_type(event) → String`.
  - `Axn::Webhooks.swallow_soft_error(desc, exception:)` — logs (raises in dev when `Axn.config.raise_piping_errors_in_dev`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/outbound/dsl_spec.rb
# frozen_string_literal: true

require "base64"

RSpec.describe "Axn::Webhooks.outbound" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('secret')}" }

  it "captures signer, events, and retry curve; resolves static targets" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      max_attempts 5
      backoff ->(attempt) { attempt * 10 }
      event :lead_signed, to: ["https://os.example/hook"]
    end

    config = Axn::Webhooks::Outbound.config
    expect(config.targets_for(:lead_signed)).to eq(["https://os.example/hook"])
    expect(config.max_attempts).to eq(5)
    expect(config.backoff.call(3)).to eq(30)
    expect(config.wire_type(:lead_signed)).to eq("lead_signed")
    expect(config.signer.call(id: "m", timestamp: 1, body: "b")).to include("webhook-signature")
  end

  it "supports a per-event wire type override" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, type: "lead.signed", to: ["https://x"]
    end
    expect(Axn::Webhooks::Outbound.config.wire_type(:lead_signed)).to eq("lead.signed")
  end

  it "falls back to the block-level `subscribers` resolver when an event has no `to:`" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      subscribers ->(event) { ["https://resolved/#{event}"] }
      event :lead_closed
    end
    expect(Axn::Webhooks::Outbound.config.targets_for(:lead_closed)).to eq(["https://resolved/lead_closed"])
  end

  it "raises loudly on an unknown event, listing the known ones" do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: ["https://x"]
    end
    expect { Axn::Webhooks::Outbound.config.targets_for(:nope) }
      .to raise_error(Axn::Webhooks::Error, /unknown outbound event :nope.*lead_signed/m)
  end

  it "raises when config is read before `outbound` is declared" do
    Axn::Webhooks::Outbound.reset!
    expect { Axn::Webhooks::Outbound.config }.to raise_error(Axn::Webhooks::Error, /no `outbound` block/)
  end

  it "warns (does not raise) at boot when an event has a statically empty target list" do
    expect(Axn.config.logger).to receive(:warn).with(/lead_signed.*empty/i)
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('s')}"
      event :lead_signed, to: []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/dsl_spec.rb`
Expected: FAIL — `undefined method 'outbound' for Axn::Webhooks`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/outbound/config.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # The resolved, immutable outbound declaration. One per process (a single `outbound` block).
      class Config
        DEFAULT_MAX_ATTEMPTS = 8
        DEFAULT_BACKOFF = ->(attempt) { [30 * (3**(attempt - 1)), 6 * 3600].min }

        def initialize(signer:, events:, default_subscribers:, max_attempts:, backoff:)
          @signer = signer
          @events = events                      # { Symbol => { to:, type: } }
          @default_subscribers = default_subscribers
          @max_attempts = max_attempts || DEFAULT_MAX_ATTEMPTS
          @backoff = backoff || DEFAULT_BACKOFF
        end

        attr_reader :signer, :max_attempts, :backoff

        def events = @events.keys

        def wire_type(event)
          fetch(event)[:type] || event.to_s
        end

        # Static Array `to:` wins; else the block-level `subscribers` resolver; else [].
        def targets_for(event)
          spec = fetch(event)
          list = spec[:to] || @default_subscribers&.call(event) || []
          Array(list)
        end

        private

        def fetch(event)
          @events.fetch(event.to_sym) do
            raise Axn::Webhooks::Error,
                  "unknown outbound event #{event.inspect} (known: #{events.map(&:inspect).join(', ')})"
          end
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks/outbound/dsl.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Receiver for the `Axn::Webhooks.outbound do … end` block.
      class DSL
        def initialize
          @events = {}
          @sign_spec = nil
          @default_subscribers = nil
          @max_attempts = nil
          @backoff = nil
        end

        def sign(strategy = nil, **opts, &block)
          @sign_spec = { strategy:, opts:, block: }
        end

        def subscribers(resolver = nil, &block)
          @default_subscribers = resolver || block
        end

        def max_attempts(value) = @max_attempts = value
        def backoff(callable = nil, &block) = @backoff = callable || block

        # rubocop:disable Naming/MethodParameterName
        def event(name, to: nil, type: nil)
          @events[name.to_sym] = { to:, type: }
        end
        # rubocop:enable Naming/MethodParameterName

        # Internal: build the resolved Config, validating declarations.
        def __config__
          raise Axn::Webhooks::Error, "outbound block must declare `sign`" if @sign_spec.nil?

          @events.each do |name, spec|
            next unless spec[:to].is_a?(Array) && spec[:to].empty?

            Axn.config.logger.warn("[axn-webhooks] outbound event #{name.inspect} declares an empty `to:` — it will deliver nowhere")
          end

          Config.new(
            signer: Signer.build(**@sign_spec),
            events: @events,
            default_subscribers: @default_subscribers,
            max_attempts: @max_attempts,
            backoff: @backoff,
          )
        end
      end
    end
  end
end
```

```ruby
# lib/axn/webhooks/outbound.rb
# frozen_string_literal: true

require_relative "outbound/signer"
require_relative "outbound/envelope"
require_relative "outbound/transport"
require_relative "outbound/config"
require_relative "outbound/dsl"

module Axn
  module Webhooks
    # Process-global registration for outbound webhook emission (a single `outbound` block).
    module Outbound
      @config = nil

      class << self
        def install(config) = @config = config
        def reset! = @config = nil

        def config
          @config || raise(Axn::Webhooks::Error, "no `outbound` block declared — call Axn::Webhooks.outbound { … } at boot")
        end
      end
    end

    # Declare outbound emission. Evaluated at boot (e.g. a Rails initializer).
    def self.outbound(&block)
      raise ArgumentError, "Axn::Webhooks.outbound requires a block" unless block

      dsl = Outbound::DSL.new
      dsl.instance_exec(&block)
      Outbound.install(dsl.__config__)
    end

    # Local stand-in for the future promoted axn-core soft-error helper (see the outbound spec's
    # Dependencies): logs a swallowed exception, but raises in development when configured.
    def self.swallow_soft_error(desc, exception:)
      raise exception if Axn.config.raise_piping_errors_in_dev && Axn.config.env.development?

      Axn.config.logger.warn("[axn-webhooks] ignoring error while #{desc}: #{exception.class}: #{exception.message}")
      nil
    end
  end
end
```

Replace the individual `require_relative "webhooks/outbound/signer"` / `envelope` / `transport` lines added in Tasks 1–3 with a single `require_relative "webhooks/outbound"` in `lib/axn/webhooks.rb` (the umbrella file now requires them).

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/dsl_spec.rb`
Expected: PASS. Then `bundle exec rspec spec/axn/webhooks/outbound` to confirm Tasks 1–3 still load.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/outbound.rb lib/axn/webhooks/outbound/config.rb lib/axn/webhooks/outbound/dsl.rb lib/axn/webhooks.rb spec/axn/webhooks/outbound/dsl_spec.rb
git commit -m "feat(outbound): outbound DSL + Config registry + swallow_soft_error shim"
```

---

### Task 5: Deliver axn — one attempt, receipt confirmation, self-managed retry

The delivery engine. Signs per-attempt (fresh timestamp, stable `webhook-id`), POSTs, classifies the response, and either succeeds, quietly fails (permanent 4xx), reschedules itself (retryable, attempts remain), or reports once + fails (exhausted). Reads secret/curve/transport from `Outbound.config` so the job payload stays JSON-simple and secret-free.

**Files:**
- Create: `lib/axn/webhooks/outbound/deliver.rb`
- Modify: `lib/axn/webhooks/outbound.rb` (add `require_relative "outbound/deliver"`)
- Test: `spec/axn/webhooks/outbound/deliver_spec.rb`

**Interfaces:**
- Consumes: `Outbound.config` (`.signer`, `.max_attempts`, `.backoff`, `.transport`); `Transport::RETRYABLE_NETWORK_ERRORS`; `Axn.config.on_exception`.
- Produces: `Axn::Webhooks::Outbound::Deliver` axn. `expects :url, :webhook_id, :body, :event`; `expects :attempt, default: 1`. On a retryable outcome it calls `self.class.call_async(url:, webhook_id:, body:, event:, attempt: attempt + 1, _async: { wait: delay })`. Success → `done!`; permanent 4xx → `fail!`; exhausted → report + `fail!`.
- Note: `Outbound::Config` gains a `transport` reader (default `Axn::Webhooks::Outbound::Transport`). Add `transport` to the DSL (`def transport(obj) = @transport = obj`) and thread it through `Config.new(transport:)`, defaulting to the module. Add these three lines in Task 4's files if not already present, or here — keep the edit in whichever task the reviewer runs first; the test below assumes `config.transport` exists.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/outbound/deliver_spec.rb
# frozen_string_literal: true

require "base64"

RSpec.describe Axn::Webhooks::Outbound::Deliver do
  after { Axn::Webhooks::Outbound.reset! }

  # A recording fake transport; `script` maps call-index -> Response or a raise.
  def fake_transport(*responses)
    Class.new do
      define_method(:calls) { @calls ||= [] }
      define_method(:post) do |url:, body:, headers:|
        calls << { url:, body:, headers: }
        outcome = responses[calls.size - 1] || responses.last
        raise outcome if outcome.is_a?(Class) || outcome.is_a?(Exception)

        outcome
      end
    end.new
  end

  def ok(status, headers = {}) = Axn::Webhooks::Outbound::Transport::Response.new(status:, headers:)

  def declare!(transport:, max_attempts: 8, backoff: ->(_n) { 60 })
    t = transport
    ma = max_attempts
    bo = backoff
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      transport t
      max_attempts ma
      backoff bo
      event :lead_signed, to: ["https://os.example/hook"]
    end
  end

  let(:kwargs) { { url: "https://os.example/hook", webhook_id: "msg_1", body: '{"a":1}', event: "lead_signed" } }

  it "signs per attempt and succeeds on 2xx" do
    transport = fake_transport(ok(202))
    declare!(transport:)

    result = described_class.call(**kwargs)

    expect(result).to be_ok
    headers = transport.calls.first[:headers]
    expect(headers["webhook-id"]).to eq("msg_1")
    expect(headers["webhook-signature"]).to start_with("v1,")
    expect(headers["content-type"]).to eq("application/json")
  end

  it "quietly fails (no reschedule) on a permanent 4xx" do
    transport = fake_transport(ok(422))
    declare!(transport:)
    allow(described_class).to receive(:call_async)

    result = described_class.call(**kwargs)

    expect(result).not_to be_ok
    expect(result.outcome).to be_failure
    expect(result.outcome).not_to be_exception
    expect(described_class).not_to have_received(:call_async)
  end

  it "reschedules with backoff on a retryable 5xx when attempts remain" do
    transport = fake_transport(ok(503))
    declare!(transport:, backoff: ->(n) { n * 100 })
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs.merge(attempt: 1))

    expect(described_class).to have_received(:call_async).with(
      hash_including(webhook_id: "msg_1", attempt: 2, _async: { wait: 100 }),
    )
  end

  it "honors Retry-After when it exceeds the computed backoff" do
    transport = fake_transport(ok(429, "retry-after" => "300"))
    declare!(transport:, backoff: ->(_n) { 60 })
    allow(described_class).to receive(:call_async)

    described_class.call(**kwargs.merge(attempt: 1))

    expect(described_class).to have_received(:call_async).with(hash_including(_async: { wait: 300 }))
  end

  it "reschedules (does not raise) on a retryable network error" do
    transport = fake_transport(Timeout::Error)
    declare!(transport:, backoff: ->(_n) { 60 })
    allow(described_class).to receive(:call_async)

    result = described_class.call(**kwargs.merge(attempt: 1))

    expect(result).to be_ok # rescheduled, current attempt acked
    expect(described_class).to have_received(:call_async).with(hash_including(attempt: 2))
  end

  it "reports once and fails (no reschedule) when retries are exhausted" do
    transport = fake_transport(ok(500))
    declare!(transport:, max_attempts: 3)
    allow(described_class).to receive(:call_async)
    expect(Axn.config).to receive(:on_exception).at_least(:once)

    result = described_class.call(**kwargs.merge(attempt: 3))

    expect(result).not_to be_ok
    expect(described_class).not_to have_received(:call_async)
  end

  it "lets an unexpected (non-network) transport exception propagate as a loud exception" do
    transport = fake_transport(ArgumentError.new("boom"))
    declare!(transport:)

    result = described_class.call(**kwargs)
    expect(result.outcome).to be_exception
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/deliver_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::Outbound::Deliver` (and `config.transport` undefined until wired).

- [ ] **Step 3: Write minimal implementation**

First, thread a `transport` through the DSL/Config (if not already done). In `lib/axn/webhooks/outbound/dsl.rb` add `@transport = nil` in `initialize`, `def transport(obj) = @transport = obj`, and pass `transport: @transport` to `Config.new`. In `lib/axn/webhooks/outbound/config.rb` add `transport:` to `initialize` (store `@transport = transport || Transport`) and `attr_reader :transport`.

```ruby
# lib/axn/webhooks/outbound/deliver.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # A single delivery attempt + the self-managed retry engine. Built as an Axn: metrics/OTel/
      # structured logs per attempt come free. Retryable responses reschedule via axn's
      # adapter-agnostic call_async(_async: { wait: }) seam (never branching on adapter type);
      # unexpected exceptions propagate so the async adapter retries the un-acked job (at-least-once).
      class Deliver
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :url, type: String
        expects :webhook_id, type: String
        expects :body, type: String
        expects :event, type: String
        expects :attempt, type: Integer, default: 1

        def call
          response = post
          return if success?(response.status)                 # 2xx -> done
          return retry_or_exhaust!(retry_after: response.headers["retry-after"]) if retryable?(response.status)

          fail!("permanent delivery failure (HTTP #{response.status}) for #{event} to #{url}")
        rescue *Transport::RETRYABLE_NETWORK_ERRORS => e
          retry_or_exhaust!(network_error: e)
        end

        private

        def config = Axn::Webhooks::Outbound.config

        def post
          config.transport.post(url:, body:, headers: signed_headers)
        end

        # Sign per attempt with a FRESH timestamp (so the receiver's replay window accepts a retry),
        # reusing the stable webhook_id for idempotent dedup.
        def signed_headers
          config.signer.call(id: webhook_id, timestamp: Time.now.to_i, body:)
                .merge("content-type" => "application/json", "user-agent" => user_agent)
        end

        def user_agent = "axn-webhooks/#{Axn::Webhooks::VERSION}"

        def success?(status) = (200..299).cover?(status)

        # 5xx, plus the "come back later" 4xx codes.
        def retryable?(status) = status >= 500 || [429].include?(status)

        def retry_or_exhaust!(retry_after: nil, network_error: nil)
          if attempt >= config.max_attempts
            report_exhaustion(network_error)
            return fail!("delivery exhausted after #{attempt} attempts for #{event} to #{url}")
          end

          delay = [config.backoff.call(attempt), parse_retry_after(retry_after)].compact.max
          self.class.call_async(url:, webhook_id:, body:, event:, attempt: attempt + 1, _async: { wait: delay })
        end

        def parse_retry_after(value)
          return nil if value.nil? || value.to_s.empty?

          Integer(value, 10) if value.to_s.match?(/\A\d+\z/)
        end

        # Report ONCE at exhaustion via axn's configured reporter (Honeybadger at Teamshares),
        # WITHOUT raising — raising would trigger the adapter to retry the already-exhausted job.
        def report_exhaustion(network_error)
          error = network_error || Axn::Webhooks::Error.new("outbound delivery exhausted for #{event} to #{url}")
          Axn.config.on_exception(error, action: self.class, context: { event:, url:, webhook_id:, attempt: })
        rescue StandardError => e
          Axn::Webhooks.swallow_soft_error("reporting outbound delivery exhaustion", exception: e)
        end
      end
    end
  end
end
```

Add to `lib/axn/webhooks/outbound.rb`: `require_relative "outbound/deliver"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/deliver_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/outbound/deliver.rb lib/axn/webhooks/outbound.rb lib/axn/webhooks/outbound/dsl.rb lib/axn/webhooks/outbound/config.rb spec/axn/webhooks/outbound/deliver_spec.rb
git commit -m "feat(outbound): Deliver — receipt confirmation + self-managed retry engine"
```

---

### Task 6: Emit axn + `Axn::Webhooks.emit` fan-out

Ties it together: validate the event (loud on typo), resolve targets, and enqueue one `Deliver` per target with a fresh `webhook-id` each. Warns when falling back to synchronous inline delivery (no adapter configured).

**Files:**
- Create: `lib/axn/webhooks/outbound/emit.rb`
- Modify: `lib/axn/webhooks/outbound.rb` (require + `Axn::Webhooks.emit`)
- Test: `spec/axn/webhooks/outbound/emit_spec.rb`

**Interfaces:**
- Consumes: `Outbound.config` (`.targets_for`, `.wire_type`); `Outbound::Envelope`; `Outbound::Deliver`.
- Produces:
  - `Axn::Webhooks::Outbound::Emit` axn — `expects :event`, `expects :data, default: {}`; resolves targets and, per target, generates `Envelope.new_id`, builds the body, and enqueues `Deliver`.
  - `Axn::Webhooks.emit(event, data: {}) → Axn::Result` (delegates to `Emit.call!`, so an unknown event raises loudly).
  - Deliver dispatch respects async-when-configured, else sync inline fallback with a one-time warn (uses the same presence check the inbound `Dispatch` uses; never a type branch).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/outbound/emit_spec.rb
# frozen_string_literal: true

require "base64"
require "json"

RSpec.describe "Axn::Webhooks.emit" do
  after { Axn::Webhooks::Outbound.reset! }

  before do
    Axn::Webhooks.outbound do
      sign :standard_webhooks, secret: "whsec_#{Base64.strict_encode64('secret')}"
      event :lead_signed, to: ["https://a.example/hook", "https://b.example/hook"]
    end
    # Capture Deliver enqueues without running HTTP. Deliver has no adapter in the test env, so the
    # Emit fan-out uses the sync inline path unless we stub; stub call to record instead.
    allow(Axn::Webhooks::Outbound::Deliver).to receive(:call)
  end

  it "raises loudly on an unknown event" do
    expect { Axn::Webhooks.emit(:not_a_real_event, data: {}) }
      .to raise_error(Axn::Webhooks::Error, /unknown outbound event/)
  end

  it "fans out one delivery per target, each with a distinct webhook-id and the wire type" do
    Axn::Webhooks.emit(:lead_signed, data: { lead_id: 42 })

    expect(Axn::Webhooks::Outbound::Deliver).to have_received(:call).twice
    calls = []
    expect(Axn::Webhooks::Outbound::Deliver).to have_received(:call) { |**kw| calls << kw }.twice

    urls = calls.map { |c| c[:url] }
    ids = calls.map { |c| c[:webhook_id] }
    expect(urls).to contain_exactly("https://a.example/hook", "https://b.example/hook")
    expect(ids.uniq.size).to eq(2) # distinct id per (emission x target)

    body = JSON.parse(calls.first[:body])
    expect(body).to include("type" => "lead_signed", "data" => { "lead_id" => 42 })
    expect(body["id"]).to eq(calls.first[:webhook_id])
  end

  it "warns when delivering synchronously because no async adapter is configured" do
    expect(Axn.config.logger).to receive(:warn).with(/synchronous|no async adapter/i).at_least(:once)
    Axn::Webhooks.emit(:lead_signed, data: {})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/outbound/emit_spec.rb`
Expected: FAIL — `undefined method 'emit' for Axn::Webhooks`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/outbound/emit.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    module Outbound
      # Resolves an event's subscribers and enqueues one Deliver per target. Built as an Axn so an
      # unknown event (a typo) is a loud, reported failure instead of today's silent no-op.
      class Emit
        include Axn
        include Axn::Webhooks::VendorFacet

        expects :event
        expects :data, type: Hash, default: {}

        def call
          config = Axn::Webhooks::Outbound.config
          type = config.wire_type(event)

          config.targets_for(event).each do |url|
            id = Envelope.new_id
            body = Envelope.build(id:, type:, data:)
            enqueue(url:, webhook_id: id, body:, event: type)
          end
        end

        private

        # Async when an adapter is configured for Deliver, else a warned best-effort sync fallback
        # (no cross-process retries). Presence check only — never branches on adapter type.
        def enqueue(**kwargs)
          if async_configured?
            Deliver.call_async(**kwargs)
          else
            Axn.config.logger.warn(
              "[axn-webhooks] delivering #{kwargs[:event]} synchronously (no async adapter configured) — " \
              "best-effort, no cross-process retries",
            )
            Deliver.call(**kwargs)
          end
        end

        def async_configured?
          if Deliver.respond_to?(:_async_adapter) && !Deliver._async_adapter.nil?
            return !!Deliver._async_adapter
          end

          !!Axn.config._default_async_adapter
        end
      end
    end
  end
end
```

Add to `lib/axn/webhooks/outbound.rb`: `require_relative "outbound/emit"`, and the module method:

```ruby
    # Emit an outbound webhook event. Fans out one signed, self-retrying delivery per subscriber.
    # Raises loudly (Axn::Webhooks::Error) on an unknown event.
    def self.emit(event, data: {})
      Outbound::Emit.call!(event:, data:)
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/outbound/emit_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/outbound/emit.rb lib/axn/webhooks/outbound.rb spec/axn/webhooks/outbound/emit_spec.rb
git commit -m "feat(outbound): Emit fan-out + Axn::Webhooks.emit"
```

---

### Task 7: Inbound `retry_later!` — RetryLater error + `Response.service_unavailable`

The receiver-side half of the 503 delivery contract: a handler can request redelivery without paging.

**Files:**
- Create: `lib/axn/webhooks/errors.rb`
- Modify: `lib/axn/webhooks.rb` (require it early, before other files that reference `Error`), `lib/axn/webhooks/response.rb`
- Test: `spec/axn/webhooks/errors_spec.rb`, additions to `spec/axn/webhooks/response_spec.rb`

**Interfaces:**
- Produces:
  - `Axn::Webhooks::RetryLater < Axn::Webhooks::Error` with `#retry_after → Integer|nil`.
  - `Axn::Webhooks.retry_later!(after: nil)` — raises `RetryLater`.
  - `Axn::Webhooks::Response.service_unavailable(retry_after: nil) → Response` (status 503, `retry-after` header when given).
- Note: `Axn::Webhooks::Error` currently lives in `lib/axn/webhooks.rb`. Move its definition into `errors.rb` and `require_relative "webhooks/errors"` as the FIRST require in `lib/axn/webhooks.rb` (before `request`/`response`/etc.), so `RetryLater` and `Error` are defined before any consumer.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/webhooks/errors_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Webhooks.retry_later!" do
  it "raises RetryLater carrying the retry-after seconds" do
    expect { Axn::Webhooks.retry_later!(after: 120) }
      .to raise_error(Axn::Webhooks::RetryLater) { |e| expect(e.retry_after).to eq(120) }
  end

  it "RetryLater is an Axn::Webhooks::Error" do
    expect(Axn::Webhooks::RetryLater.new).to be_a(Axn::Webhooks::Error)
  end
end
```

```ruby
# append to spec/axn/webhooks/response_spec.rb
RSpec.describe Axn::Webhooks::Response, ".service_unavailable" do
  it "is a 503 with a retry-after header when given" do
    resp = described_class.service_unavailable(retry_after: 90)
    expect(resp.status).to eq(503)
    expect(resp.headers["retry-after"]).to eq("90")
  end

  it "omits retry-after when not given" do
    expect(described_class.service_unavailable.headers).not_to have_key("retry-after")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/errors_spec.rb spec/axn/webhooks/response_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Webhooks::RetryLater`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/webhooks/errors.rb
# frozen_string_literal: true

module Axn
  module Webhooks
    class Error < StandardError; end

    # Raised by a handler (via Axn::Webhooks.retry_later!) to ask the sender to redeliver later —
    # mapped to 503 + Retry-After by the inbound endpoint. Distinct from a crash (a reported 500):
    # a deliberate, un-paged "come back later".
    class RetryLater < Error
      attr_reader :retry_after

      def initialize(message = "retry later", retry_after: nil)
        @retry_after = retry_after
        super(message)
      end
    end

    def self.retry_later!(after: nil)
      raise RetryLater.new(retry_after: after)
    end
  end
end
```

In `lib/axn/webhooks.rb`: remove the `class Error < StandardError; end` line from the module body, and add `require_relative "webhooks/errors"` as the first `require_relative` (immediately after `require "active_support/deprecation"`).

In `lib/axn/webhooks/response.rb`, add after `self.xml`:

```ruby
      def self.service_unavailable(retry_after: nil)
        headers = retry_after ? { "retry-after" => retry_after.to_s } : {}
        new(status: 503, headers:)
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/errors_spec.rb spec/axn/webhooks/response_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/errors.rb lib/axn/webhooks.rb lib/axn/webhooks/response.rb spec/axn/webhooks/errors_spec.rb spec/axn/webhooks/response_spec.rb
git commit -m "feat(inbound): RetryLater error, retry_later!, Response.service_unavailable"
```

---

### Task 8: Wire `retry_later!` through Dispatch + Endpoint (→ 503)

A handler raising `RetryLater` during synchronous dispatch becomes a 503 + `Retry-After`, not a reported 500.

**Files:**
- Modify: `lib/axn/webhooks/dispatch.rb`, `lib/axn/webhooks/inbound/endpoint.rb`
- Test: additions to `spec/axn/webhooks/dispatch_spec.rb`, `spec/axn/webhooks/inbound/handle_spec.rb` (or `to_response`-focused spec)

**Interfaces:**
- Consumes: `Axn::Webhooks::RetryLater` (Task 7); `Response.service_unavailable` (Task 7).
- Produces: `Dispatch` exposes `retry_after` (`allow_nil: true`); when the sync handler raises `RetryLater`, Dispatch catches it and exposes `retry_after` (result stays `ok?`, not an exception). `Endpoint#to_response` maps a present `retry_after` to `Response.service_unavailable`.

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/webhooks/dispatch_spec.rb
RSpec.describe "Axn::Webhooks::Dispatch retry_later" do
  after { Axn::Webhooks::Inbound.reset! }

  it "catches a handler RetryLater as a non-exception result exposing retry_after" do
    stub_const("RetryingHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 45)
    end)

    router = Axn::Webhooks::Inbound::Router.new(to: "RetryingHandler")
    result = Axn::Webhooks::Dispatch.call(
      request: Axn::Webhooks::Request.new(raw_body: "{}"),
      router:, parse: Axn::Webhooks::Parsers.build(:json), mode: :sync,
    )

    expect(result).to be_ok
    expect(result.outcome).not_to be_exception
    expect(result.retry_after).to eq(45)
  end
end
```

```ruby
# append to spec/axn/webhooks/inbound/handle_spec.rb
RSpec.describe "Endpoint#to_response retry_later" do
  after { Axn::Webhooks::Inbound.reset! }

  it "maps a handler retry_later! to 503 + Retry-After" do
    stub_const("DeferHandler", Class.new do
      include Axn
      expects :event, allow_blank: true
      def call = Axn::Webhooks.retry_later!(after: 60)
    end)

    Axn::Webhooks.inbound(:vendor) do
      verify { |_req| true }
      dispatch to: "DeferHandler", mode: :sync
    end

    response = Axn::Webhooks::Inbound[:vendor].to_response(Axn::Webhooks::Request.new(raw_body: "{}"))
    expect(response.status).to eq(503)
    expect(response.headers["retry-after"]).to eq("60")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_spec.rb spec/axn/webhooks/inbound/handle_spec.rb`
Expected: FAIL — `retry_after` undefined / response is 500 not 503.

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/webhooks/dispatch.rb`: add `exposes :retry_after, allow_nil: true` next to the existing `exposes :handler_result`, and change the synchronous handler invocation so `RetryLater` is caught:

```ruby
        expose handler_result: nil
        begin
          expose handler_result: handler_class.call!(**args)
        rescue Axn::Webhooks::RetryLater => e
          expose retry_after: e.retry_after
        end
```

(Replace the existing final `expose handler_result: handler_class.call!(**args)` line. Leave the async path unchanged — `retry_later!` requires synchronous handling to influence the response.)

In `lib/axn/webhooks/inbound/endpoint.rb`, `#response_for`, add as the FIRST check (before the exception/failure checks):

```ruby
          return Response.service_unavailable(retry_after: dispatched.retry_after) if dispatched.retry_after
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/webhooks/dispatch_spec.rb spec/axn/webhooks/inbound/handle_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/webhooks/dispatch.rb lib/axn/webhooks/inbound/endpoint.rb spec/axn/webhooks/dispatch_spec.rb spec/axn/webhooks/inbound/handle_spec.rb
git commit -m "feat(inbound): map handler retry_later! to 503 + Retry-After"
```

---

### Task 9: Docs — README delivery contract + CHANGELOG

**Files:**
- Modify: `README.md`, `CHANGELOG.md`
- Test: none (docs). Verify with `bundle exec rake` at the end.

- [ ] **Step 1: Add the outbound section to README**

Add a `## Outbound (sending webhooks)` section covering: the `Axn::Webhooks.outbound do … end` declaration (with the `subscribers` resolver sugar), `Axn::Webhooks.emit(:event, data:)`, the Standard-Webhooks envelope + per-attempt signing, and the injectable `transport`. Include the **delivery contract table** verbatim from the spec (`§4`), documenting what each response code means for both a gem-based and a single-side receiver, and the `retry_later!` (503 + `Retry-After`) affordance. Add an explicit note: **routing is sender-owned config today; the DB-backed self-registration store is intentionally deferred until a real use-case (the `subscribers`/`to:` lambda is the seam).**

- [ ] **Step 2: Add CHANGELOG entries under `## [Unreleased]` → `### Added`**

```markdown
- `Axn::Webhooks.outbound do … end` + `Axn::Webhooks.emit(:event, data:)` — declare signed outbound
  webhooks (symbol-keyed events, `to:` static list or `subscribers` resolver lambda, per-event `type:`
  wire-name override) and emit them. An unknown event raises loudly instead of silently no-op'ing.
- `Axn::Webhooks::Outbound::Deliver` — per-subscriber delivery as an Axn with receipt confirmation and
  a self-managed exponential-backoff retry engine: 2xx succeeds; 5xx/429/timeout/connection errors
  reschedule via axn's adapter-agnostic `call_async(_async: { wait: })` (honoring `Retry-After`);
  other 4xx are a quiet permanent failure; exhaustion is reported once (never raises, so the adapter
  doesn't re-retry). Signs per attempt (fresh `webhook-timestamp`, stable `webhook-id`); the secret
  is read from config at delivery time, never serialized into the job payload.
- `Axn::Webhooks::Outbound::Signer` / `Envelope` / `Transport` — Standard-Webhooks signing headers
  (reusing `Axn::Webhooks::Signature`), the `{id,timestamp,type,data}` envelope, and a stdlib
  `net/http` transport (injectable; no new runtime dependency).
- `Axn::Webhooks.retry_later!(after:)` + `Axn::Webhooks::RetryLater` + `Response.service_unavailable`
  — a handler can ask the sender to redeliver later, mapped to `503` + `Retry-After` (distinct from a
  crash's reported 500; requires synchronous dispatch).
- `Axn::Webhooks.swallow_soft_error` — a local dev-loud/prod-quiet helper for best-effort paths
  (temporary stand-in for a future promoted axn-core helper).
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: outbound usage, delivery contract, CHANGELOG"
```

---

### Task 10: Full suite + rubocop, and integration smoke test

A final end-to-end test proving emit → sign → deliver against the inbound verifier (both halves of the shared primitive agree), plus the full gate.

**Files:**
- Create: `spec/axn/webhooks/outbound/integration_spec.rb`

- [ ] **Step 1: Write the round-trip test**

```ruby
# spec/axn/webhooks/outbound/integration_spec.rb
# frozen_string_literal: true

require "base64"

# Proves the outbound Signer and the inbound verify :standard_webhooks strategy agree: a body signed
# for delivery verifies against the receiver's verifier using the fresh per-attempt timestamp.
RSpec.describe "outbound signing <-> inbound verification round-trip" do
  after { Axn::Webhooks::Outbound.reset! }

  let(:secret) { "whsec_#{Base64.strict_encode64('shared-secret')}" }

  it "an outbound-signed request passes the inbound verifier" do
    signer = Axn::Webhooks::Outbound::Signer.build(strategy: :standard_webhooks, opts: { secret: }, block: nil)
    id = "msg_round_trip"
    ts = Time.now.to_i
    body = Axn::Webhooks::Outbound::Envelope.build(id:, type: "lead_signed", data: { lead_id: 1 })
    # Envelope uses its own timestamp; sign with the same ts we present in the header.
    headers = signer.call(id:, timestamp: ts, body:)

    request = Axn::Webhooks::Request.new(
      raw_body: body,
      headers: {
        "webhook-id" => headers["webhook-id"],
        "webhook-timestamp" => headers["webhook-timestamp"],
        "webhook-signature" => headers["webhook-signature"],
      },
    )

    verifier = Axn::Webhooks::Verifiers.build(strategy: :standard_webhooks, opts: { secret: }, block: nil)
    expect(verifier.call(request)).to be(true)
  end
end
```

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/axn/webhooks/outbound/integration_spec.rb`
Expected: PASS. If it fails on the timestamp/signature, confirm the signer signs `id.timestamp.body` with `encoding: :base64` and the header is `v1,<sig>` (matches `Verifiers::StandardWebhooks`).

- [ ] **Step 3: Run the full gate**

Run: `bundle exec rake`
Expected: all specs pass, rubocop clean. Fix any rubocop offenses (match surrounding style: `module_function`, frozen string literal, `Data.define`, keyword args).

- [ ] **Step 4: Run the Rails suite (dual-layout parity)**

Run: `bundle exec rake spec_rails` (if the outbound code is exercised there; at minimum confirm it still boots).
Expected: PASS / no load errors.

- [ ] **Step 5: Commit**

```bash
git add spec/axn/webhooks/outbound/integration_spec.rb
git commit -m "test(outbound): signing <-> verification round-trip"
```

---

## Self-Review

**1. Spec coverage:**
- Sender-owned routing + resolver seam → Task 4 (`Config#targets_for`, `subscribers` sugar). ✅
- DB deferral documented → Task 9. ✅
- `:standard_webhooks` signing via shared `Signature` → Task 1 + Task 10 round-trip. ✅
- Symbol-keyed API + loud unknown event → Task 4 (`targets_for` raise) + Task 6 (`emit`). ✅
- Wire `type` default + override → Task 4 (`wire_type`). ✅
- SW envelope + headers → Task 2 + Task 5 (`signed_headers`). ✅
- Per-target fan-out, distinct `webhook-id` → Task 6. ✅
- `webhook-id` stable across retries → Task 5 (reschedule reuses `webhook_id`). ✅
- Per-attempt re-signing (replay window) → Task 5 (`signed_headers` fresh timestamp). ✅
- Async `:auto` posture + warned sync fallback → Task 6 (`enqueue`/`async_configured?`). ✅
- Self-managed retry, own decay, `Retry-After`, exhaustion reported once, at-least-once crash net → Task 5. ✅
- Secret never in payload → Task 5 (reads from config). ✅
- No new runtime dep (stdlib transport, injectable) → Task 3. ✅
- Observability (Axns, `vendor_facet`) → Tasks 5/6 (`include Axn`, `include VendorFacet`). ✅
- Inbound `retry_later!` → 503 + `Retry-After` → Tasks 7–8. ✅
- axn-core soft-error helper shimmed locally (promotion is a separate ticket) → Task 4. ✅

**2. Placeholder scan:** No TBD/TODO; every code step has real code and every test has assertions. ✅

**3. Type consistency:** `Signer.build(strategy:, opts:, block:)` matches the verify-spec shape and both callers (Task 1 test, Task 4 `Signer.build(**@sign_spec)`). `Config` readers (`signer`/`max_attempts`/`backoff`/`transport`/`targets_for`/`wire_type`) are consistent across Tasks 4–6. `Deliver` kwargs (`url`/`webhook_id`/`body`/`event`/`attempt`) match between the reschedule call, the Emit enqueue, and the specs. `Transport::Response(status:, headers:)` consistent across Tasks 3/5. `RetryLater#retry_after` / `Dispatch` `retry_after` exposure / `Response.service_unavailable(retry_after:)` consistent across Tasks 7/8. ✅

---

## Execution Handoff

(Filled in when handing off — see skill.)
