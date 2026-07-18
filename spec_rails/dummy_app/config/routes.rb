# frozen_string_literal: true

Rails.application.routes.draw do
  mount Axn::Webhooks::Inbound[:test_vendor], at: "/webhooks/test_vendor" if Axn::Webhooks::Inbound.registered.include?(:test_vendor)
end
