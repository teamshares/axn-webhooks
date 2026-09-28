# frozen_string_literal: true

module Axn
  module Webhooks
    # A deferred request-value lookup used inside an `inbound` block, e.g.
    # `verify :hmac, signature: header("X-Sig")`. Called with the Request at verify time.
    class Resolver
      def initialize(&blk)
        @blk = blk
      end

      def call(request) = @blk.call(request)
    end

    module Resolvers
      module_function

      def header(name) = Resolver.new { |req| req.header(name) }
      def raw_body     = Resolver.new(&:raw_body)
      def params       = Resolver.new(&:params)
      def url          = Resolver.new(&:url)

      # Resolve a declared value against the request:
      #   Resolver -> call(request); Symbol -> request.public_send(sym);
      #   Proc -> call(request) (or call for a 0-arity proc); else the literal.
      # Exactly the shapes `resolve` below defers — the single source of truth for "is this resolved
      # per request, or used as a literal?". Boot-time secret checks ask this rather than
      # `respond_to?(:call)`: a credential-provider object or a Method responds to #call but is NOT
      # resolved here, so exempting it from validation let it declare cleanly and then fail every
      # request with a type error instead of failing loudly at boot (Codex review).
      #
      # A Resolver and a Symbol are this gem's DSL conventions; everything else (a Proc, or a literal)
      # is axn core's `Axn::Extensions::Auth` rule, so the two gems that accept inbound requests agree
      # on what a deferred secret is.
      def deferred?(value) = value.is_a?(Resolver) || value.is_a?(Symbol) || Axn::Extensions::Auth.deferred?(value)

      def resolve(value, request)
        case value
        when Resolver then value.call(request)
        when Symbol   then request.public_send(value)
        else Axn::Extensions::Auth.resolve(value, request)
        end
      end
    end
  end
end
