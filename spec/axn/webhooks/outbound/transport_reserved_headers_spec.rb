# frozen_string_literal: true

require "socket"
require "timeout"

# Drives a REAL socket, deliberately: `transport_spec.rb` stubs `Net::HTTP#request`, and the
# rewriting this file is about happens inside that very call — so a stubbed test cannot observe it.
# Pins Transport::RESERVED_HEADERS to what Net::HTTP actually does on the wire, so neither a stdlib
# change nor an edit to the constant can drift from reality unnoticed.
RSpec.describe "Axn::Webhooks::Outbound::Transport reserved headers" do
  def sentinel = "SENTINELVALUE123"

  # Returns the raw request head the server received.
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

  Axn::Webhooks::Outbound::Transport::RESERVED_HEADERS.each do |reserved|
    it "cannot deliver a value under #{reserved.inspect} — Net::HTTP rewrites it after the headers are applied" do
      expect(post_with(reserved)).not_to include(sentinel)
    end
  end

  # The control: if these ever started being clobbered too, RESERVED_HEADERS would be understating
  # the problem and a signature could silently vanish under one of them.
  %w[Host Connection Accept-Encoding X-Signature Webhook-Signature].each do |survivor|
    it "delivers a value under #{survivor.inspect} untouched" do
      expect(post_with(survivor)).to include(sentinel)
    end
  end
end
