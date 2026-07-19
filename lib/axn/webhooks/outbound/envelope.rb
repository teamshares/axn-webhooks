# frozen_string_literal: true

require "json"
require "securerandom"

module Axn
  module Webhooks
    module Outbound
      # Builds the Standard Webhooks message body and its idempotency id. The body is fixed at
      # emit time (part of the dedup identity); the SIGNATURE is recomputed per delivery attempt
      # (see Deliver), so this carries no signing concern.
      module Envelope
        module_function

        def new_id = "msg_#{SecureRandom.uuid}"

        def build(id:, type:, data:, now: Time.now)
          JSON.generate(id:, timestamp: now.to_i, type: type.to_s, data:)
        end
      end
    end
  end
end
