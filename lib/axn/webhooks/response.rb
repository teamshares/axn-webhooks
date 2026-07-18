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
        @body = body.to_s
        @headers = headers.transform_keys(&:to_s)
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
