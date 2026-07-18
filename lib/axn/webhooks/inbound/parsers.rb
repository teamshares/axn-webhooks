# frozen_string_literal: true

require "json"

module Axn
  module Webhooks
    # Builds the callable that turns a Request into the parsed `event` a dispatcher routes on.
    module Parsers
      module_function

      def build(option)
        case option
        when nil, :json then ->(request) { JSON.parse(request.raw_body) }
        when Proc       then option
        else raise Axn::Webhooks::Error, "unknown parse option #{option.inspect} (use :json or a proc)"
        end
      end
    end
  end
end
