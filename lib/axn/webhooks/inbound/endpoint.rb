# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # A registered inbound webhook endpoint. Verifies a request's signature, dispatches
      # the (verified, parsed) event to a handler Axn, and maps the pipeline's outcome to an
      # HTTP Response. Challenge (GET) and Rack mount arrive in a later phase.
      class Endpoint
        def initialize(name:, verifier:, dispatch: nil, respond: nil, static_respond: nil, challenge: nil,
                       unauthorized_headers: nil, challenge_required: nil)
          if dispatch && dispatch[:mode] == :async && respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares a custom `respond` but explicit `dispatch mode: :async` " \
                  "can't produce a handler_result for it to read — use `mode: :sync` (or omit mode) or drop the respond block"
          end

          if respond && static_respond
            raise Axn::Webhooks::Error,
                  "inbound endpoint `#{name}` declares both `respond` and `static_respond` — declare only one; " \
                  "`respond` reads the handler's result, `static_respond` doesn't and renders on every non-error outcome"
          end

          @name = name.to_sym
          @verifier = verifier
          @dispatch = dispatch
          @respond = respond
          @static_respond = static_respond
          @challenge = challenge
          @unauthorized_headers = unauthorized_headers
          @challenge_required = challenge_required

          validate_challenge!
        end

        attr_reader :name

        # Headers attached to the 401 a verify failure produces. Empty for the signature
        # strategies — there is nothing for a signing client to be challenged *with* — but
        # mandatory for HTTP Basic auth (RFC 7617), where a client that doesn't authenticate
        # preemptively sends its first request bare and repeats it with credentials only after a
        # 401 carrying `WWW-Authenticate`. Without this the second leg never comes and every
        # request from such a client is dropped, uniformly and silently.
        #
        # An explicit `unauthorized_headers` declaration wins, so a custom `verify` block can
        # supply its own challenge; otherwise the verifier speaks for itself.
        def unauthorized_headers
          return @unauthorized_headers if @unauthorized_headers
          return @verifier.unauthorized_headers if @verifier.respond_to?(:unauthorized_headers)

          {}
        end

        # Is this request an authentication attempt at all? When it isn't, there is nothing to
        # verify — it's a protocol precondition, not a failed verification — and #to_response
        # answers with the challenge without invoking Verify (PRO-3148). Under a two-legged scheme
        # like RFC 7617 Basic auth a reactive client sends one such request per *successful*
        # webhook, so recording them as verify failures made the highest-volume outcome on a healthy
        # endpoint a recorded failure, and a cross-vendor verify-failure monitor unusable without
        # knowing which vendors happen to use Basic auth.
        #
        # False unless something says otherwise, so the signature strategies — which have no
        # challenge to offer and no second leg to wait for — are untouched.
        #
        # Note this is NOT the `challenge` declaration (that's the vendor's GET handshake, see
        # #challenge_response). Same word, different protocol: this one is the 401 kind.
        def challenge_required?(request)
          return !!@challenge_required.call(request) if @challenge_required
          return @verifier.challenge_required?(request) if @verifier.respond_to?(:challenge_required?)

          false
        end

        # Verify the request's signature. Returns an Axn::Result: ok? when verified,
        # a failure on mismatch, an exception if the verifier raises.
        def verify(request)
          Verify.call(request:, verifier: @verifier, vendor: @name)
        end

        # Full pipeline: verify, then (if a dispatch is declared and verification passed)
        # parse + route to the handler. Returns the final Axn::Result.
        def handle(request)
          verified = verify(request)
          return verified unless verified.ok? && @dispatch

          Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                        mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
        end

        # The staged HTTP outcome mapping (spec: "Respond + staged outcome model"). Verify and
        # dispatch are mapped in separate branches — deliberately NOT a single outcome->status
        # rule, because a verify failure (401) and a handler business fail! (2xx) are both
        # `outcome.failure?` but mean opposite things at the HTTP layer.
        def to_response(request)
          # Ahead of verify, deliberately: a request that isn't an authentication attempt gets the
          # challenge rather than a recorded verify failure (see #challenge_required?). Same 401 on
          # the wire, and it still can't reach a handler — strictly safer than the `done!` that
          # would settle this leg as a *success*.
          return Response.new(status: 401, headers: unauthorized_headers) if challenge_required?(request)

          verified = verify(request)
          return Response.new(status: 401, headers: unauthorized_headers) unless verified.ok?
          return default_ack unless @dispatch

          dispatched = Dispatch.call(request:, router: @dispatch[:router], parse: @dispatch[:parse],
                                     mode: @dispatch[:mode], respond_declared: !@respond.nil?, vendor: @name)
          response_for(dispatched)
        end

        # The GET branch (spec: the mount owns the whole path, every verb). Testable without a Rack
        # env, mirroring #verify/#handle/#to_response.
        def challenge_response(request)
          return Response.new(status: 405) unless @challenge

          # The Challenge axn computes the exact Response (200 echo / 403 guard-fail / 400 nil).
          # Only a raising resolver/guard makes it not-ok -> a reported 500.
          result = Challenge.call(request:, resolver: @challenge[:resolver], guard: @challenge[:guard], vendor: @name)
          result.ok? ? result.response : Response.new(status: 500)
        end

        # The Rack app entry point (spec: mount-first packaging). `Inbound[:vendor]` (this object)
        # is directly `mount`-able in Rails routes.rb or `run`-able in a bare Rack::Builder — the
        # mount owns the whole path and every verb: POST -> #to_response, GET -> #challenge_response,
        # anything else -> 405. Named `call`, deliberately reserved since Phase 3 (see #handle).
        def call(env)
          built = BuildRequest.call(env:, vendor: @name)
          return Response.new(status: 500).to_rack unless built.ok?

          request = built.request
          response =
            case request.http_method
            when "POST" then to_response(request)
            when "GET" then challenge_response(request)
            else Response.new(status: 405)
            end
          response.to_rack
        end

        private

        # A challenge with nothing in it is the PRO-3146 silent drop: the client is told to retry and
        # never told how, so every request is dropped forever — and now without even a verify failure
        # recorded, since answering the challenge skips Verify. Fails the boot rather than shipping an
        # endpoint that is both broken and invisible. Reads the *effective* headers, so declaring
        # `challenge_required` alongside a verifier that carries its own challenge (`verify
        # :basic_auth`) is fine — only a hand-rolled endpoint with neither lands here.
        def validate_challenge!
          return unless @challenge_required && unauthorized_headers.empty?

          raise Axn::Webhooks::Error,
                "inbound endpoint `#{@name}` declares `challenge_required` but has no challenge to send — " \
                "declare `unauthorized_headers` too, or the challenged client is never told how to retry"
        end

        def response_for(dispatched)
          return Response.service_unavailable(retry_after: dispatched.retry_after) if dispatched.retry_later
          return default_ack(status: unparseable_status) if unparseable?(dispatched)
          return Response.new(status: 500) if dispatched.outcome.exception?
          return default_ack if dispatched.outcome.failure?    # handler fail! -> quiet ack (or static body)
          return default_ack if dispatched.handler_result.nil? # otherwise: :ack / async enqueue -> ack (or static body)
          return default_ack unless @respond

          # Run the user's respond block inside the Respond axn so a raise in it (e.g. reading a
          # missing exposure) becomes a reported 500, not an exception escaping the HTTP mapper.
          responded = Respond.call(handler_result: dispatched.handler_result, responder: @respond, vendor: @name)
          responded.ok? ? responded.response : Response.new(status: 500)
        end

        # A verified request whose body doesn't parse (PRO-3143). Checked ahead of the generic
        # exception -> 500 branch: it IS an exception outcome (already reported via on_exception, which
        # is how you learn a vendor is sending garbage), but a retry can never fix malformed bytes, so
        # the HTTP answer is terminal instead of an invitation to redeliver forever.
        def unparseable?(dispatched) = dispatched.exception.is_a?(Axn::Webhooks::UnparseableBody)

        # This endpoint's declaration wins over the global setting; see the setting's own comment for
        # why the default is a 2xx rather than the semantically-tidier 400.
        def unparseable_status = @dispatch[:unparseable_status] || Axn::Webhooks.config.unparseable_status

        # The bare-ack default, or the declared static_respond body in its place. Every branch
        # above that used to hardcode `Response.ack` (dispatch.failure?, nil handler_result, no
        # respond declared, no dispatch at all) now goes through here — static_respond, unlike
        # respond, has no handler_result to read, so it renders on all of them uniformly.
        #
        # `status:` restamps the rendered response, for the one caller (the unparseable-body row) whose
        # status the gem decides rather than the block. Left nil by every other caller, so a block that
        # picked its own status — `text("queued", status: 202)` — still keeps it on the success rows.
        # A raising/non-Response static_respond block is still a 500 here: an internal error in the
        # endpoint's own body-rendering isn't the vendor's malformed body, and shouldn't be acked as one.
        def default_ack(status: nil)
          return Response.ack(status: status || 200) unless @static_respond

          responded = StaticRespond.call(responder: @static_respond, vendor: @name)
          return Response.new(status: 500) unless responded.ok?

          status ? responded.response.with_status(status) : responded.response
        end
      end
    end
  end
end
