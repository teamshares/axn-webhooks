# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Receiver for an `inbound` block: captures declarations (Phase 2: `verify`) and
      # exposes request resolvers. Later phases add dispatch/challenge/respond here.
      class DSL
        # Every declaration a child `endpoint` inherits. Deliberately excludes @child_endpoints
        # (nesting is one level deep) and @nested.
        #
        # Also excludes @dispatch_spec, which cannot be inherited because a parent declaring
        # `dispatch` alongside `endpoint` blocks is rejected at registration (see
        # Axn::Webhooks.inbound). Listing it would be inert, and it would advertise a shared-dispatch
        # feature that does not work anyway: `dispatch` captures ONE spec hash, so a child
        # re-declaring it replaces the parent's wholesale — there is no partial override, and a
        # parent dispatch every child copies verbatim leaves the children differing by nothing
        # (Codex review asked for this; declined for that reason plus the migration hazard the guard
        # exists to catch — silently losing Inbound[:vendor] out from under a mounted route).
        INHERITED_IVARS = %i[
          @verify_spec @unauthorized_headers @challenge_required
          @respond_block @static_respond_block @challenge_spec
        ].freeze

        # verify :hmac, **opts | verify :standard_webhooks, **opts | verify { |req| ... }
        def verify(strategy = nil, **opts, &block)
          @verify_spec = { strategy:, opts:, block: }
        end

        # unauthorized_headers "WWW-Authenticate" => %(Basic realm="Webhook")
        #
        # Headers to attach to the 401 a verify failure produces. `verify :basic_auth` supplies
        # this itself; declare it only for a custom `verify` block that has to challenge a client
        # into retrying with credentials (see Endpoint#unauthorized_headers).
        def unauthorized_headers(headers)
          @unauthorized_headers = headers
        end

        # challenge_required { |req| req.header("Authorization").to_s.empty? }
        #
        # Declares which requests are not authentication attempts at all, and so get the challenge
        # (401 + `unauthorized_headers`) instead of being run through `verify` and recorded as
        # verify failures. `verify :basic_auth` answers this itself; declare it only for a custom
        # `verify` block that wraps a two-legged scheme the gem can't see through — the shape
        # buyout's Twilio routes use, where the BasicAuth verifier sits inside a block:
        #
        #   challenge_required { |req| my_basic_auth.challenge_required?(req) }
        def challenge_required(&block)
          @challenge_required = block
        end

        # dispatch to: "Handler" | dispatch on: ->(e){…}, to: {map}, otherwise:, via: | parse: | mode:
        # `unparseable_status:` overrides Axn::Webhooks.config.unparseable_status for THIS endpoint —
        # it belongs here, next to `parse:`, because it only describes what happens when that parse
        # fails, and because the right value is a fact about one vendor's retry policy (PRO-3143).
        # rubocop:disable Naming/MethodParameterName
        def dispatch(to: nil, on: nil, otherwise: nil, via: nil, parse: :json, mode: :auto, unparseable_status: nil)
          @dispatch_spec = { to:, on:, otherwise:, via:, parse:, mode:, unparseable_status: }
        end
        # rubocop:enable Naming/MethodParameterName

        # respond { |handler_result| text("...") } — maps a genuine handler success to a
        # Response. Every other outcome (ack, business fail!, verify failure/exception, or a
        # no-dispatch endpoint) always gets the default bare ack (or a declared `static_respond`
        # body — see below), regardless of this declaration — see Endpoint#to_response.
        def respond(&block)
          # Endpoint rejects having both renderers set, and a child inherits BOTH ivars — so
          # overriding an inherited `static_respond` with a `respond` has to clear it, or the child
          # raises. Clears only an INHERITED one: declaring both in the same block stays an error
          # rather than silently becoming last-one-wins (Codex review).
          discard_inherited(:@static_respond_block)
          @respond_block = block
          claim_ownership(:@respond_block)
        end

        # static_respond { text("...") } — a body that does NOT read the handler result (block
        # takes zero args, unlike respond's `|handler_result|`), so it renders on every non-error
        # outcome: sync success, async enqueue, otherwise: :ack, and business fail! — see
        # Endpoint#default_ack. Mutually exclusive with `respond` (Endpoint#initialize raises if
        # both are declared) and never forces sync dispatch (Dispatch#async? never reads it).
        def static_respond(&block)
          if block && !block.parameters.empty?
            raise Axn::Webhooks::Error,
                  "inbound endpoint's static_respond block must take no arguments (it never reads the " \
                  "handler's result, unlike respond) — got a parameter; use `respond` instead if you need " \
                  "to read the handler's result"
          end

          discard_inherited(:@respond_block) # see `respond` — cross-form override, inherited only
          @static_respond_block = block
          claim_ownership(:@static_respond_block)
        end

        # challenge ->(req){ req.params["challenge"] }                          — Nylas
        # challenge ->(req){ req.params["hub.challenge"] }, if: ->(req){ ... }  — Meta
        def challenge(resolver, if: nil)
          # `if:` shadows Ruby's `if` keyword inside this method body — must read it back via
          # binding.local_variable_get, not a bare `if` reference (that's a syntax trap, not a var).
          guard = binding.local_variable_get(:if)
          @challenge_spec = { resolver:, guard: }
        end

        def header(name) = Resolvers.header(name)
        def raw_body     = Resolvers.raw_body
        def params       = Resolvers.params
        def url          = Resolvers.url

        # Dispatch-map sugar: `async("H")` == `{ call: "H", async: true }`; `sync` forces sync.
        # Callable inside a `dispatch to: { … }` map because the `inbound` block is instance_exec'd
        # against this DSL. Extra kwargs (e.g. `with:`) pass through: `async("H", with: ->(e){ … })`.
        # `**opts` is spread FIRST so the fixed mode and the positional handler always win — a
        # splatted shared options hash carrying `:async`/`:call` can never silently flip the mode
        # or retarget the handler (the helper's name is its contract).
        def async(call, **opts) = { **opts, call:, async: true }
        def sync(call, **opts)  = { **opts, call:, async: false }

        # endpoint(:events) { dispatch … } — declares a CHILD endpoint that inherits everything the
        # parent block declared and may override any of it by re-declaring. One `inbound :slack`
        # block with two `endpoint` blocks registers Inbound[:slack_interactivity] and
        # Inbound[:slack_events]; the parent itself registers nothing.
        def endpoint(name, &block)
          raise ArgumentError, "`endpoint #{name.inspect}` requires a block" unless block
          raise ArgumentError, "`endpoint #{name.inspect}` cannot be nested inside another `endpoint` — one level only" if @nested

          @child_endpoints ||= {}
          raise ArgumentError, "duplicate `endpoint #{name.inspect}` in the same inbound block" if @child_endpoints.key?(name.to_sym)

          @child_endpoints[name.to_sym] = block
        end

        # Drops an ivar this DSL INHERITED from a parent `endpoint` container, leaving one declared
        # in this very block untouched. Backs the mutually-exclusive renderer override above.
        def discard_inherited(ivar)
          return unless @inherited_ivars&.include?(ivar)

          instance_variable_set(ivar, nil)
          @inherited_ivars.delete(ivar)
        end

        # Marks an ivar as belonging to THIS block from here on. Without it, a child that
        # re-declared `respond` left `@respond_block` still listed as inherited, so a following
        # `static_respond` discarded the child's OWN block and the pair was accepted — exactly the
        # same-block conflict the discard rule is supposed to keep raising (Codex review).
        def claim_ownership(ivar) = @inherited_ivars&.delete(ivar)

        # Internal: declared child endpoints, name => block. Empty for a plain `inbound` block.
        def __children__ = @child_endpoints || {}

        # Internal: whether `dispatch` was declared directly on THIS DSL. Read instead of
        # `__dispatch__` so the parent-with-children check doesn't build a Router just to ask.
        def __dispatch_declared? = !@dispatch_spec.nil?

        # Internal: a fresh DSL seeded with this one's captured declarations, with `block` evaluated
        # against it — so a child inherits everything and overrides by re-declaring.
        #
        # Copies the ivars rather than re-`instance_exec`ing the parent block per child (the obvious
        # alternative): replaying the parent block would re-run any side effects in it, and would
        # re-enter `endpoint` recursively, registering each child once per sibling.
        def __child_dsl__(block)
          child = self.class.new
          inherited = INHERITED_IVARS.select { |ivar| instance_variable_defined?(ivar) }
          inherited.each { |ivar| child.instance_variable_set(ivar, instance_variable_get(ivar)) }
          # Recorded so `respond`/`static_respond` can tell an inherited value from one declared in
          # the child's own block, and clear only the former.
          child.instance_variable_set(:@inherited_ivars, inherited.dup)
          child.instance_variable_set(:@nested, true)
          child.instance_exec(&block)
          child
        end

        # Internal: build the verifier callable from the captured declaration.
        # For challenge-only endpoints (no dispatch, no verify declared), return a no-op verifier
        # that always succeeds — a challenge-only endpoint just handshakes the GET and 200-acks any
        # POST, so there's no unverified processing to guard against.
        # `verify` is REQUIRED whenever `dispatch` is declared — dispatching an unverified webhook
        # would run the handler on an unauthenticated request.
        def __verifier__
          unless @verify_spec
            # Nothing declared at all: bare endpoint, always an error.
            raise Axn::Webhooks::Error, "inbound endpoint declared no `verify`" if @dispatch_spec.nil? && @challenge_spec.nil?

            # `dispatch` without `verify` is unsafe regardless of whether `challenge` is also present.
            if @dispatch_spec
              raise Axn::Webhooks::Error,
                    "inbound endpoint with `dispatch` must declare `verify` — dispatching an unverified webhook is unsafe"
            end

            # Challenge-only endpoint (no dispatch): return a no-op verifier.
            return ->(_request) { true }
          end

          raise Axn::Webhooks::Error, "inbound endpoint `verify` needs a strategy or a block" if @verify_spec[:strategy].nil? && @verify_spec[:block].nil?

          Verifiers.build(**@verify_spec)
        end

        # Internal: build the { router:, parse:, mode: } dispatch config, or nil if none declared.
        def __dispatch__
          return nil unless @dispatch_spec

          spec = @dispatch_spec
          unless %i[auto sync async].include?(spec[:mode])
            raise Axn::Webhooks::Error, "dispatch mode: must be :sync, :async, or :auto (got #{spec[:mode].inspect})"
          end

          unless spec[:unparseable_status].nil? || Response.valid_status?(spec[:unparseable_status])
            raise Axn::Webhooks::Error,
                  "dispatch unparseable_status: must be an Integer HTTP status between 200 and 599 " \
                  "(got #{spec[:unparseable_status].inspect})"
          end

          router = Router.new(to: spec[:to], on: spec[:on], otherwise: spec[:otherwise], via: spec[:via])
          { router:, parse: Parsers.build(spec[:parse]), mode: spec[:mode], unparseable_status: spec[:unparseable_status] }
        end

        # Internal: the captured respond block, or nil if none declared.
        def __respond__ = @respond_block

        # Internal: the captured static_respond block, or nil if none declared.
        def __static_respond__ = @static_respond_block

        # Internal: the captured { resolver:, guard: } challenge declaration, or nil if none.
        def __challenge__ = @challenge_spec

        # Internal: the declared 401 headers, or nil to let the verifier speak for itself.
        def __unauthorized_headers__ = @unauthorized_headers

        # Internal: the declared challenge-required predicate, or nil to ask the verifier.
        def __challenge_required__ = @challenge_required
      end
    end
  end
end
