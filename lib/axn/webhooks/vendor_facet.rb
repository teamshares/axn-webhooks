# frozen_string_literal: true

module Axn
  module Webhooks
    # Included by each pipeline Axn (Verify/Dispatch/Respond/Challenge) to stamp the endpoint's
    # registered vendor name onto the pipeline as the configured observability facet
    # (Axn::Webhooks.config.vendor_facet). See internal-docs/plans/2026-07-18-axn-webhooks-inbound-
    # phase-5.md, Decision B, for why both facets are declared unconditionally: `dimension`/`tag`
    # are one-time class-level declarations, but the facet TYPE is a live runtime setting and the
    # vendor name is per-endpoint — so each resolver reads the live setting fresh, per call, and
    # "claims" the vendor value only for the currently-selected facet type. A resolver returning nil
    # makes Axn::Core::Tagging.resolve omit that facet entirely, so at most one of {dimension, tag}
    # is ever actually stamped.
    module VendorFacet
      def self.included(base)
        base.class_eval do
          expects :vendor, allow_blank: true, default: nil

          dimension :vendor, -> { vendor if Axn::Webhooks.config.vendor_facet == :dimension }
          tag       :vendor, -> { vendor if Axn::Webhooks.config.vendor_facet == :tag }
        end
      end
    end
  end
end
