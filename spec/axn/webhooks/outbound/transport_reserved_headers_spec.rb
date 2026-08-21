# frozen_string_literal: true

require "socket"
require "timeout"

# Drives a REAL socket, deliberately: `transport_spec.rb` stubs `Net::HTTP#request`, and the
# rewriting this file is about happens inside that very call — so a stubbed test cannot observe it.
#
# The two tables below are hard-coded ON PURPOSE. An earlier version generated its examples from
# `Transport::RESERVED_HEADERS`, which made the spec self-referential: deleting an entry deleted its
# own test, leaving the suite green while `HmacSigner` began accepting a header Net::HTTP eats.
# Written this way, an edit to the constant fails the equality example, and a change in Net::HTTP's
# behavior fails the wire examples.
expected_clobbered = %w[content-length transfer-encoding].freeze

# Controls. Content-Type and User-Agent belong here, not above: they survive the TRANSPORT untouched
# and are reserved for an unrelated reason — `Deliver` merges its own copies in after signing.
expected_survivors = %w[
  Host Connection Accept-Encoding X-Signature Webhook-Signature Content-Type User-Agent
].freeze

RSpec.describe "Axn::Webhooks::Outbound::Transport reserved headers" do
  def sentinel = "SENTINELVALUE123"

  # The raw request head the server received.
  def post_with(header_name)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = nil

    thread = Thread.new do
      Timeout.timeout(5) do
        sock = server.accept
        captured = +""
        captured << sock.gets until captured.include?("\r\n\r\n")
        sock.print "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        sock.close
      end
    end

    Axn::Webhooks::Outbound::Transport.post(
      url: "http://127.0.0.1:#{port}/hook", body: "hello", headers: { header_name => sentinel },
    )
    thread.join
    captured
  ensure
    server&.close
  end

  it "declares exactly the header names observed to be unusable" do
    # The guard against editing the constant. Independent of it by construction.
    expect(Axn::Webhooks::Outbound::Transport::RESERVED_HEADERS).to match_array(expected_clobbered)
  end

  expected_clobbered.each do |reserved|
    it "cannot deliver a value under #{reserved.inspect} — Net::HTTP rewrites it after the headers are applied" do
      expect(post_with(reserved)).not_to include(sentinel)
    end
  end

  expected_survivors.each do |survivor|
    it "delivers a value under #{survivor.inspect} untouched" do
      expect(post_with(survivor)).to include(sentinel)
    end
  end
end
