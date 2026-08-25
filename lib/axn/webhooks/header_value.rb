# frozen_string_literal: true

module Axn
  module Webhooks
    # THE rule for what may appear in an HTTP header value, shared by the outbound request path
    # (Outbound::Deliver#add_custom_header) and the inbound response path (Response#initialize).
    #
    # Deliberately one shared home rather than a copy per side: the outbound half already enforced
    # this while the inbound half did not, which is the same "fixed only where it was noticed"
    # pattern that let a secret-handling bug recur four times in this gem.
    module HeaderValue
      # RFC 7230's `field-value` grammar forbids every control byte except HTAB (0x09). CR/LF
      # (0x0D/0x0A) are the response-splitting pair, but any other control byte (NUL, BEL, ...) is
      # equally invalid on the wire and can get a message rejected by a proxy in between.
      FORBIDDEN_BYTES = /[\x00-\x08\x0A-\x1F\x7F]/

      module_function

      # False for a value carrying a forbidden byte, AND for one whose encoding makes the question
      # unanswerable — an invalid/incompatible encoding raises from String#match?, and a value we
      # cannot inspect must not be trusted onto the wire.
      def safe?(value)
        !value.to_s.match?(FORBIDDEN_BYTES)
      rescue Encoding::CompatibilityError, ArgumentError
        false
      end
    end
  end
end
