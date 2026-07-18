# frozen_string_literal: true

module Axn
  module Webhooks
    module Inbound
      # Resolves a parsed webhook event to the handler to invoke. Pure logic (no Axn) —
      # a missing constant or an unmatched key with no `otherwise:` raises, and the
      # Dispatch Axn turns that raise into a reported exception + formatted result.
      class Router
        # rubocop:disable Naming/MethodParameterName
        def initialize(to:, on: nil, otherwise: nil, via: nil)
          # rubocop:enable Naming/MethodParameterName
          raise Axn::Webhooks::Error, "dispatch needs a `to:` target" if to.nil?

          @to = to
          @on = on
          @otherwise = otherwise
          @via = via
        end

        # → [handler_class, kwargs] for a matched handler, or :ack.
        def resolve(event)
          return handler_for(@to, event) if @on.nil?

          key = @on.call(event)
          @to.is_a?(Hash) ? resolve_mapped(key, event) : resolve_by_convention(key, event)
        end

        private

        def resolve_mapped(key, event)
          entry = @to.fetch(key) { return unmatched(key, event) }
          handler_for(entry, event)
        end

        def resolve_by_convention(key, event)
          transform = @via || method(:default_transform)
          [constantize("#{@to}::#{transform.call(key)}"), { event: }]
        end

        def handler_for(entry, event)
          case entry
          when String then [constantize(entry), { event: }]
          when Hash
            args = entry.key?(:with) ? entry.fetch(:with).call(event) : { event: }
            [constantize(entry.fetch(:call)), args]
          else
            raise Axn::Webhooks::Error, "invalid dispatch target: #{entry.inspect}"
          end
        end

        def unmatched(key, event)
          case @otherwise
          when :ack then :ack
          when nil  then raise Axn::Webhooks::Error, "no handler for webhook event #{key.inspect} (and no `otherwise:`)"
          else
            @otherwise.call(event) # user callable (e.g. alerting); return value ignored
            :ack
          end
        end

        def constantize(name) = Object.const_get(name)

        def default_transform(key) = key.to_s.split(/[._]/).reject(&:empty?).map(&:capitalize).join
      end
    end
  end
end
