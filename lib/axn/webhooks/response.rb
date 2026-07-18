# frozen_string_literal: true

module Axn
  module Webhooks
    # A Rails-agnostic HTTP response value: status + body + headers. Produced by
    # `Endpoint#to_response` from the verify->dispatch pipeline's Axn::Result; Phase 5's Rack
    # mount renders this — nothing here touches Rack.
    class Response
      attr_reader :status, :body, :headers

      def initialize(status: 200, body: "", headers: {})
        @status = status
        @body = body.to_s.freeze
        # Freeze keys AND values so a caller's mutable header value can't mutate the response
        # after construction (a rendered-later value object must be truly immutable).
        @headers = headers.each_with_object({}) do |(key, value), frozen|
          frozen[key.to_s.freeze] = value.frozen? ? value : value.dup.freeze
        end.freeze
        freeze
      end

      def self.ack(status: 200, headers: {}) = new(status:, headers:)

      def self.text(body, status: 200, headers: {})
        new(status:, body:, headers: { "Content-Type" => "text/plain" }.merge(headers))
      end

      def self.xml(body, status: 200, headers: {})
        new(status:, body:, headers: { "Content-Type" => "application/xml" }.merge(headers))
      end

      def ==(other)
        other.is_a?(self.class) && status == other.status && body == other.body && headers == other.headers
      end
    end
  end
end
