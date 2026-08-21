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

        # The problem with `url` as an outbound target, or nil when there is none. A predicate
        # rather than a raiser, because its two callers disagree on the error class: a declaration
        # mistake at boot is an ArgumentError (see validate_url!), while a bad one-off `emit(to:)`
        # URL is an Axn::Webhooks::Error a caller may rescue at runtime (see Outbound::Emit). Shape
        # only (no host policy) -- Emit's one-off `to:` override doesn't have a Config instance's
        # `allowed_hosts`/`allow_url` in scope at this call site yet; closing that gap is tracked
        # separately (PRO-3214 follow-up), not silently done here.
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
                       allowed_hosts: nil, allow_url: nil)
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
        # Every raw entry -- a bare URL String (today's shape) or a `{ url:, id: }` Hash (a
        # DB-backed row) -- goes through the SAME `TargetPolicy` a statically-declared `to:` Array
        # was already checked against at boot (`validate_event!` below), so a runtime resolver can
        # never see a looser bar than a hand-written Array does.
        def resolve_subscribers(event)
          spec = fetch(event)
          raw = spec[:to].nil? ? call_resolver(@default_subscribers, event) : resolve_to(spec[:to], event)

          subscribers = []
          rejections = []
          Array(raw).each do |target|
            subscribers << TargetPolicy.check!(target, allowed_hosts:, allow_url:)
          rescue Axn::Webhooks::InvalidTarget => e
            rejections << { target: target.inspect, reason: e.message }
          end

          Resolution.new(subscribers:, rejections:)
        end

        # Back-compat convenience for callers that only want the resolved URLs and don't care about
        # a malformed row -- e.g. today's `Emit` fan-out. Silently drops rejections; a caller that
        # needs to know about (or report) them wants `resolve_subscribers` directly.
        def targets_for(event)
          resolve_subscribers(event).subscribers.map(&:url)
        end

        private

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
        def config_owned(value)
          case value
          when String then value.dup.freeze
          when Array then value.map { |element| config_owned(element) }.freeze
          else value
          end
        end

        def fetch(event)
          @events.fetch(event.to_sym) do
            raise Axn::Webhooks::Error,
                  "unknown outbound event #{event.inspect} (known: #{events.map(&:inspect).join(', ')})"
          end
        end

        # Arity-aware via `CallableArity` (not bare `#arity`): a plain callable OBJECT -- a very
        # plausible DB-store shape, e.g. `Subscription::Store.new` -- has no `#arity` of its own and
        # would NoMethodError here before this fix. `CallableArity.accepts?` falls back to
        # `callable.method(:call).parameters` for exactly that case.
        def call_resolver(callable, event)
          return nil if callable.nil?

          CallableArity.accepts?(callable, 1) ? callable.call(event) : callable.call
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
