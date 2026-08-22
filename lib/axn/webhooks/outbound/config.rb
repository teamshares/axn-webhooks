# frozen_string_literal: true

require "uri"

module Axn
  module Webhooks
    module Outbound
      # The resolved, immutable outbound declaration. One per process (a single `outbound` block).
      class Config
        # Validated settings via the upstream Axn::Configurable DSL (class flavor) — max_attempts/
        # backoff/transport/vendor/user_agent/timeouts are simple, independently valid-or-not values.
        # `events` (and its `to:`/URL structure) stays hand-written below: it's a Hash built and
        # cross-validated as a whole from one DSL block, not a flat setting.
        extend Axn::Configurable::Settings

        DEFAULT_MAX_ATTEMPTS = 8
        # Equal jitter (half fixed, half random): a fan-out event whose receiver is down would
        # otherwise have every failing target retry in lockstep, converging on the same instant.
        DEFAULT_BACKOFF = lambda do |attempt|
          base = [30 * (3**(attempt - 1)), 6 * 3600].min
          ((base / 2.0) + (rand * base / 2.0)).round
        end
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_READ_TIMEOUT = 10

        setting :max_attempts, default: DEFAULT_MAX_ATTEMPTS,
                               validate: ->(v) { (v.is_a?(Integer) && v.positive?) || "must be a positive Integer" }
        # The default itself IS a callable (not a value computed BY one) — a bare Proc default would
        # otherwise be read as "call this with no args to derive the default" (Configurable's dynamic-
        # default convention) and blow up on DEFAULT_BACKOFF's required `attempt` arg. A zero-arity
        # wrapper resolves to the lambda itself instead.
        # `arity == 1 || arity.negative?` alone can't tell "one required positional" apart from "one
        # required KEYWORD" (same arity, one raises on `.call(attempt)`) or "needs 2+ positional, has
        # a splat" (negative arity, still too few args) — see CallableArity.
        setting :backoff, default: -> { DEFAULT_BACKOFF },
                          validate: lambda { |v|
                            next "must be a callable accepting the attempt number" unless v.respond_to?(:call)

                            CallableArity.accepts?(v, 1) || "must be a callable accepting the attempt number"
                          }
        # Same reasoning as `backoff`: `Transport` is a Module, and Configurable's non-dynamic default
        # path calls `.dup` on it — silently swapping in an anonymous copy that fails every `== Transport`
        # identity check downstream (e.g. Deliver's timeout-forwarding guard).
        setting :transport, default: -> { Transport }
        setting :vendor
        # Deliver's `resolve_user_agent_suffix` calls a callable value with NO arguments (a zero-arg
        # invocation is the documented contract) — one that requires an argument would otherwise boot
        # successfully and raise ArgumentError on every real delivery (Codex P2 finding).
        setting :user_agent,
                validate: lambda { |v|
                  next true unless v.respond_to?(:call)

                  CallableArity.accepts?(v, 0) || "callable must accept zero arguments (resolved with no args per delivery attempt)"
                }
        # Forwarded straight to Net::HTTP (see Transport), which calls `.zero?`/compares on whatever
        # it's given — an unvalidated non-Numeric (e.g. a String from `ENV.fetch("OPEN_TIMEOUT")`)
        # would otherwise raise NoMethodError mid-delivery instead of failing at boot (Codex P2
        # finding).
        TIMEOUT_VALIDATE = ->(v) { (v.is_a?(Numeric) && v.positive?) || "must be a positive Numeric" }
        setting :open_timeout, default: DEFAULT_OPEN_TIMEOUT, validate: TIMEOUT_VALIDATE
        setting :read_timeout, default: DEFAULT_READ_TIMEOUT, validate: TIMEOUT_VALIDATE
        # A host policy, not a network one: neither this nor `allow_url` resolves DNS, so neither is
        # proof against DNS rebinding or a hostname that later resolves to a private IP. Both nil by
        # default (any http(s) URL passes), so an existing `outbound` block is unaffected. See
        # TargetPolicy for the actual matching semantics (case-insensitive, `*.suffix` wildcard).
        setting :allowed_hosts,
                validate: lambda { |v|
                  next true if v.is_a?(Array) && v.all? { |h| h.is_a?(String) && !h.strip.empty? }

                  "must be an Array of non-empty host Strings"
                }
        # Required arity 1 (the parsed URI) -- unlike `user_agent`/a signing `secret`, there is no
        # useful zero-arg reading of a URL-allow predicate; matches `backoff`'s "the callable's whole
        # purpose is examining its argument" precedent.
        setting :allow_url,
                validate: lambda { |v|
                  next "must be a callable accepting the parsed URL" unless v.respond_to?(:call)

                  CallableArity.accepts?(v, 1) || "must be a callable accepting the parsed URL"
                }
        # Per-destination extra headers (e.g. a subscriber's bearer token), resolved fresh per
        # DELIVERY ATTEMPT from the Subscriber -- never stored, same convention `sign`'s `secret:`
        # follows -- so nothing here ever sits in a Sidekiq job payload. 0-arity (ignores the
        # subscriber) or 1-arity (receives it); nil by default (no extra headers).
        setting :headers,
                validate: lambda { |v|
                  next "must be a callable accepting zero or one arguments (the resolved Subscriber)" unless v.respond_to?(:call)

                  (CallableArity.accepts?(v, 0) || CallableArity.accepts?(v, 1)) ||
                    "must be a callable accepting zero or one arguments (the resolved Subscriber)"
                }

        # The problem with `url` as an outbound target, or nil when there is none. A predicate
        # rather than a raiser, because its two callers disagree on the error class: a declaration
        # mistake at boot is an ArgumentError (see validate_url!), while a bad one-off `emit(to:)`
        # URL is an Axn::Webhooks::Error a caller may rescue at runtime (see Outbound::Emit). Shape
        # only (no host policy) -- `Outbound::Emit#resolve_targets` applies `allowed_hosts`/
        # `allow_url` itself via `TargetPolicy.check!` for the one-off `to:` override; this predicate
        # stays a pure URL-shape check so `validate_url!`'s narrower boot-time contract doesn't drift.
        def self.url_problem(url)
          TargetPolicy.parse_url!(url)
          nil
        rescue Axn::Webhooks::InvalidTarget => e
          e.message
        end

        # rubocop:disable Metrics/ParameterLists -- one kwarg per DSL setting, mirroring `DSL#__config__`'s
        # call site 1:1; a Hash-options refactor would ripple through every caller for no real gain.
        def initialize(signer:, events:, default_subscribers:, max_attempts:, backoff:, transport:,
                       vendor: nil, user_agent: nil, open_timeout: nil, read_timeout: nil,
                       allowed_hosts: nil, allow_url: nil, headers: nil)
          # rubocop:enable Metrics/ParameterLists
          @signer = signer
          @events = events # { Symbol => { to:, type:, vendor: } }
          @default_subscribers = default_subscribers

          self.max_attempts = max_attempts unless max_attempts.nil?
          self.backoff = backoff unless backoff.nil?
          self.transport = transport unless transport.nil?
          self.vendor = vendor unless vendor.nil?
          self.user_agent = user_agent unless user_agent.nil?
          self.open_timeout = open_timeout unless open_timeout.nil?
          self.read_timeout = read_timeout unless read_timeout.nil?
          self.allowed_hosts = allowed_hosts unless allowed_hosts.nil?
          self.headers = headers unless headers.nil?
          self.allow_url = allow_url unless allow_url.nil?

          @events.each { |name, spec| validate_event!(name, spec) }

          deep_freeze!
        end

        attr_reader :signer

        def events = @events.keys

        def wire_type(event)
          (fetch(event)[:type] || event).to_s
        end

        # A per-event `vendor:` overrides the block-level default; same precedence as `type:`.
        def vendor_for(event)
          fetch(event)[:vendor] || vendor
        end

        # `resolve_subscribers`'s return value: `subscribers` is the Array of validated `Subscriber`s
        # to actually fan out to; `rejections` is `{ target:, reason: }` for every row TargetPolicy
        # refused. Rejection is PER ROW -- one malformed subscriber (or one your `allowed_hosts`/
        # `allow_url` policy refuses) never discards the rest of a fan-out.
        Resolution = Data.define(:subscribers, :rejections)

        # A DECLARED per-event `to:` always wins, even when it resolves to zero targets — a static
        # Array as-is (including `[]`), or a lambda `->(event){…}` invoked (arity-aware, matching
        # Resolvers.resolve) and its result wrapped in Array (nil -> []). The block-level
        # `subscribers` resolver is ONLY consulted when the event declared no `to:` at all
        # (spec[:to].nil?) — never as a fallback for a declared resolver returning nil.
        #
        # A static `to:` Array is validated ONCE, at boot (`validate_event!`) -- so its entries are
        # only ever re-COERCED into Subscribers here, never re-checked against `TargetPolicy`.
        # Re-running it on every resolution would be wasted work for a target that can never
        # change, and would actually BREAK a stateful/rate-limited `allow_url` predicate: it could
        # reject an already-boot-validated static target later, contradicting the documented
        # once-at-boot contract (Codex P2 finding). Every OTHER raw entry -- from a callable `to:`
        # or the `subscribers` fallback, neither checkable at boot since they depend on runtime
        # state -- goes through the SAME `TargetPolicy` a static Array was checked against, so a
        # runtime resolver can never see a looser bar than a hand-written Array does.
        def resolve_subscribers(event)
          spec = fetch(event)
          return static_resolution(spec) if spec[:to].is_a?(Array)

          raw = spec[:to].nil? ? call_resolver(@default_subscribers, event) : resolve_to(spec[:to], event)
          check_targets(raw)
        end

        # Back-compat convenience for callers that only want the resolved URLs and don't care about
        # a malformed row -- e.g. today's `Emit` fan-out. Silently drops rejections; a caller that
        # needs to know about (or report) them wants `resolve_subscribers` directly. Frozen: for a
        # static `to:` Array, `resolve_subscribers` used to return the SAME frozen Array `deep_freeze!`
        # already produced; going through `Subscriber`/`.map` builds a fresh one, which `.map` never
        # freezes on its own -- `targets_for`'s own immutability contract (asserted in
        # config_immutability_spec.rb) has to be re-established here explicitly.
        def targets_for(event)
          resolve_subscribers(event).subscribers.map(&:url).freeze
        end

        # Scalars a rejected target's `#inspect` is safe to show verbatim in `redact_target`
        # below: a bare-value target (the common malformed cases -- nil, a wrong-type url, a
        # stray Integer) carries no OTHER fields that could hide a credential. NOT String: a
        # webhook URL commonly embeds a credential itself (HTTP Basic userinfo, a signed/token
        # query param) -- see `redact_target`'s dedicated String handling.
        SAFE_TO_INSPECT = [Numeric, Symbol, NilClass, TrueClass, FalseClass].freeze

        private

        # Every element already passed `TargetPolicy.check!` (shape + host policy) at boot, via
        # `validate_event!` -- constructing the `Config` at all is proof of that, so re-running it
        # here could only ever re-confirm a fact already established, at the cost of the once-at-
        # boot contract `resolve_subscribers`'s doc comment above describes. `Subscriber.coerce`
        # alone (no TargetPolicy) does the Hash/String/Subscriber normalization without re-touching
        # the host policy.
        def static_resolution(spec)
          Resolution.new(subscribers: spec[:to].map { |target| Subscriber.coerce(target) }, rejections: [])
        end

        def check_targets(raw)
          subscribers = []
          rejections = []
          wrap_targets(raw).each do |target|
            subscribers << TargetPolicy.check!(target, allowed_hosts:, allow_url:)
          rescue Axn::Webhooks::InvalidTarget => e
            rejections << { target: redact_target(target), reason: e.message }
          end

          Resolution.new(subscribers:, rejections:)
        end

        # `Kernel#Array` on a bare Hash converts it to `[[k, v], ...]` PAIRS (Hash responds to
        # `#to_a`), not `[hash]` -- so a `subscribers`/`to:` resolver returning ONE row directly
        # (an easy mistake: "return the row" is the natural instinct when there's exactly one
        # match) would otherwise have both halves of that Hash treated as separate malformed
        # targets, and the real subscriber delivered to NOBODY (Codex review). A `Subscriber`
        # already coerced (or anything else array-like) still goes through plain `Array()`.
        def wrap_targets(raw)
          return [] if raw.nil?
          return [raw] if raw.is_a?(Hash) || raw.is_a?(Subscriber)

          Array(raw)
        end

        # A safe-to-log stand-in for a rejected row: `target.inspect` verbatim would otherwise
        # copy a live credential straight into `emit`'s exposed `rejected` AND the `on_exception`
        # report -- exactly the row shape `Subscriber.coerce` rejects for carrying an unknown key
        # like `secret:` in the first place (Codex P1 finding). Only the two keys `Subscriber`
        # actually recognizes are shown as-is; every other key's NAME survives (so the rejection
        # reason -- "unknown key(s): [...]" -- and this stay legible together) but its value never
        # does. A non-Hash target (nil, a URI, ...) has nothing to redact.
        def redact_target(target)
          case target
          when Hash
            # `k` is redacted too, not just `v` -- a resolver mistake using a COMPOUND object AS A
            # KEY (e.g. a malformed `.to_h` transform keying by the record itself rather than its
            # id) would otherwise survive into the reconstructed Hash unchanged, and the outer
            # `Hash#inspect` renders that key's own #inspect regardless of what its value became
            # (Codex P1 finding, round 14).
            target.to_h { |k, v| [redact_hash_key(k), hash_target_value(k, v)] }.inspect
          when String
            # A webhook URL commonly carries a credential ITSELF -- HTTP Basic userinfo or a
            # signed/token query param -- so a rejected URL String isn't safe to `#inspect`
            # verbatim (Codex P1 finding). `TargetPolicy.redact_url` is the SAME sanitizer every
            # InvalidTarget message routes through, so a rejection's :target and its own :reason
            # can never disagree about what's safe to show.
            TargetPolicy.redact_url(target).inspect
          when *SAFE_TO_INSPECT
            target.inspect
          else
            # Anything else -- an ActiveRecord model instance is the plausible real-world case --
            # is a COMPOUND object whose own #inspect commonly renders every attribute, including
            # a secret/token column. Only the Hash-row shape has a known-safe subset (:url/:id) to
            # show; for everything else, only the class is safe to name (Codex P1 finding: the
            # earlier Hash-only redaction still leaked a model's attributes verbatim here).
            "#<#{target.class} (redacted)>"
          end
        end

        # Only a Symbol/String key is ever legitimate here (the only shapes `Subscriber.coerce`
        # accepts) -- anything else is already a rejected row on its OWN terms (an "unsupported
        # key" InvalidTarget), so only its class need survive, matching the class-only convention
        # `Subscriber.coerce`'s own message already uses for the identical shape (Codex P1 finding,
        # round 14).
        def redact_hash_key(key)
          return key if key.is_a?(Symbol) || key.is_a?(String)

          "#<#{key.class} (redacted)>"
        end

        # `:url`'s value gets the SAME URL sanitization as a bare String target -- a Hash row
        # rejected for some unrelated reason (an unknown key, say) must not leak a credential
        # embedded in its OWN `:url` value either (Codex P1 finding, round 7). `:id` is never
        # sensitive PROVIDED it's the documented scalar shape (a String/Integer identifier) --
        # `:id` is only ever stringified into that shape by `Subscriber.coerce`, which this
        # ALREADY-rejected raw row never reached, so a plausible mistake (passing the whole record
        # instead of `record.id`) leaves a COMPOUND object under `:id` here. Showing it as-is would
        # have the outer `Hash#inspect` render that object's own #inspect verbatim -- an
        # ActiveRecord-like model commonly defines that to include every attribute, secrets
        # included (Codex P1 finding, round 12). Every other key's NAME survives (so the rejection
        # reason -- "unknown key(s): [...]" -- and this stay legible together) but its value never
        # does.
        def hash_target_value(key, value)
          return TargetPolicy.redact_url(value) if key.to_s == "url" && value.is_a?(String)
          return value if key.to_s == "id" && (value.is_a?(String) || SAFE_TO_INSPECT.any? { |klass| value.is_a?(klass) })

          "<redacted>"
        end

        # Freezes the CONTAINERS we own, never the caller's objects: a `to:` resolver, the signer,
        # an injected transport and a `user_agent` callable all stay mutable — they belong to the
        # app, and freezing them could break a memoizing resolver. A statically-declared `to:`
        # Array is ours once validated, so it freezes.
        def deep_freeze!
          materialize_settings!
          @events.each_value do |spec|
            # COPY rather than freeze in place, and cover EVERY value, not just `to:`: `event to:
            # SOME_CONSTANT` would otherwise leave the application holding a frozen object it never
            # froze, while the Strings inside stayed mutable — so `url.replace("ftp://…")` rewrote
            # the published config past the boot-time validation that already ran on it, and a
            # mutable `type:`/`vendor:` rewrote `wire_type`/`vendor_for` the same way (Codex review).
            spec.transform_values! { |value| config_owned(value) }
            spec.freeze
          end
          @events.freeze
          freeze
        end

        # Read every declared setting once (so Configurable's lazy memoization happens BEFORE the
        # freeze) and replace any mutable value with a config-owned copy — `vendor`/`user_agent` are
        # plain Strings the caller may still hold, and a later `replace()` would otherwise change the
        # observability facet and the delivery User-Agent header despite the frozen-config contract
        # (Codex review). Callables, Modules and Numerics come back from config_owned untouched, so
        # only the copyable shapes are reassigned. Without this, a frozen Config raises FrozenError from the READER of any setting
        # the `outbound` block never explicitly assigned — `backoff`/`transport` escape only
        # because their defaults are dynamic (`-> { … }`) and recomputed rather than memoized.
        #
        # Derived from Configurable rather than a hand-maintained list: a constant listing the
        # settings has to be updated in lockstep with every new `setting` declaration, and
        # forgetting turns that setting's own reader into a FrozenError at runtime. Nothing to keep
        # in sync now — adding a `setting` is enough.
        def materialize_settings!
          Axn::Configurable.declared_settings_for(self.class).each_key do |name|
            value = public_send(name)
            owned = config_owned(value)
            public_send(:"#{name}=", owned) unless owned.equal?(value)
          end
        end

        # An immutable copy the config owns, for the shapes an event spec can hold. A callable `to:`
        # (or anything else the app supplied) is returned untouched — not ours to copy or freeze.
        # Hash (PRO-3214's `{ url:, id: }` row, inside a static `to:` Array) copies key-for-key
        # rather than freezing the caller's Hash in place — the identical hazard this whole method
        # exists to close, for a shape `to:`'s own String handling doesn't reach: `row[:url] =
        # "ftp://…"` after boot would otherwise rewrite a validated target through a Hash the app
        # still holds a mutable reference to. Its own keys aren't recursed into (a caller's Hash key
        # is a Symbol or String literal, never something a boot-time mutation-safety fix cares
        # about); only values are.
        def config_owned(value)
          case value
          when String then value.dup.freeze
          when Array then value.map { |element| config_owned(element) }.freeze
          when Hash then value.to_h { |k, v| [k, config_owned(v)] }.freeze
          when Subscriber
            # `Data` instances are always frozen, but that freezes only the WRAPPER -- a prebuilt
            # `Subscriber.new(url: app_string, id: ...)` still holds the app's own mutable url/id
            # Strings underneath. Worse than the String/Hash cases above: `static_resolution`
            # deliberately skips re-validating an already-boot-checked static entry, so a post-
            # boot mutation here would switch a boot-approved destination to an arbitrary host
            # with NO re-validation at all (Codex P2 finding).
            Subscriber.new(url: config_owned(value.url), id: config_owned(value.id))
          else value
          end
        end

        def fetch(event)
          @events.fetch(event.to_sym) do
            raise Axn::Webhooks::Error,
                  "unknown outbound event #{event.inspect} (known: #{events.map(&:inspect).join(', ')})"
          end
        end

        # The ORIGINAL dispatch rule, preserved byte-for-byte: pass the event unless the callable's
        # raw arity is EXACTLY zero. Deliberately raw arity (`CallableArity.zero_arity?`), not
        # `#parameters`-based `accepts?`: a pre-existing `subscribers ->(event = :all) { … }` or
        # `proc { |event = :all| … }` resolver relies on Ruby's own arity quirks (a Proc with a
        # single optional/default param reports arity 0; a lambda with one reports -1) to decide
        # whether it gets called with the event or falls back to its own default -- an
        # `accepts?`-based check (which reads `#parameters`' `:opt` LABEL rather than raw arity)
        # would flip that for the Proc case specifically, silently changing which subscribers get
        # selected (Codex P2 finding). Only made callable-object-safe here (falls back to
        # `Method#arity` via `#call`, fixing the original NoMethodError for a plain callable OBJECT
        # such as `Subscription::Store.new`) -- the dispatch RULE itself is unchanged.
        def call_resolver(callable, event)
          return nil if callable.nil?

          CallableArity.zero_arity?(callable) ? callable.call : callable.call(event)
        end

        # `to:` is "declared" whenever spec[:to] is non-nil — a static value (Array, including
        # `[]`) is returned as-is; a callable is invoked (arity-aware, via call_resolver).
        def resolve_to(raw, event)
          raw.respond_to?(:call) ? call_resolver(raw, event) : raw
        end

        # Boot-time validation, so a malformed declaration fails loudly here rather than as an
        # unexpected exception mid-delivery (which the async adapter would retry as if it were a
        # network failure). A pure declaration mistake — never triggered by runtime/user data, and
        # nothing a running app would want to rescue-and-continue past — so this raises plain
        # ArgumentError, same as `max_attempts`/`backoff` above, rather than the gem's own
        # `Axn::Webhooks::Error` (reserved for conditions a caller might legitimately rescue at
        # runtime, e.g. `fetch`'s unknown-event error below, raised on every `emit`/`targets_for`
        # call rather than once at boot).
        def validate_event!(name, spec)
          return if spec[:to].nil? || spec[:to].respond_to?(:call)

          unless spec[:to].is_a?(Array)
            raise ArgumentError,
                  "outbound event #{name.inspect} `to:` must be an Array of URLs or a callable (got #{spec[:to].class})"
          end

          spec[:to].each { |target| validate_target!(name, target) }
        end

        # Delegates to the SAME `TargetPolicy` a runtime-resolved row goes through
        # (`resolve_subscribers`), including the declared `allowed_hosts`/`allow_url` -- so a static
        # `to:` entry your own host policy would reject fails loudly at boot instead of silently
        # (well, loudly, but confusingly late) at the first emit. A pure declaration mistake, so this
        # raises plain ArgumentError like `max_attempts`/`backoff` above, not the runtime
        # `InvalidTarget` `resolve_subscribers` collects into `rejections`.
        def validate_target!(name, target)
          TargetPolicy.check!(target, allowed_hosts:, allow_url:)
        rescue Axn::Webhooks::InvalidTarget => e
          raise ArgumentError, "outbound event #{name.inspect} `to:` #{e.message}"
        end
      end
    end
  end
end
