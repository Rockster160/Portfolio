#!/usr/bin/env ruby
# Tails the fleet-telemetry feed file and POSTs each JSON record to the
# Rails webhook. Runs under systemd on prod; restart it after rotating
# the feed file. See _scripts/tesla/fleet_telemetry/SETUP.md.

require "json"
require "net/http"
require "uri"

FEED    = ENV.fetch("TELEMETRY_FEED",    "/var/log/tesla-telemetry/feed.jsonl")
WEBHOOK = URI(ENV.fetch("TELEMETRY_WEBHOOK", "http://localhost:3141/webhooks/tesla_telemetry"))

def post(http, line)
  req = Net::HTTP::Post.new(WEBHOOK.request_uri)
  req["Content-Type"] = "application/json"
  req.body = line
  res = http.request(req)
  return if res.code.to_i.between?(200, 299)

  warn "[bridge] webhook #{res.code}: #{res.body.to_s[0, 200]}"
rescue StandardError => e
  warn "[bridge] POST failed: #{e.class}: #{e.message}"
end

http = Net::HTTP.new(WEBHOOK.host, WEBHOOK.port)
http.read_timeout = 10
http.open_timeout = 5

warn "[bridge] tailing #{FEED} → #{WEBHOOK}"

IO.popen(["tail", "-n", "0", "-F", FEED], "r") do |io|
  io.each_line do |line|
    line.strip!
    next if line.empty?

    begin
      JSON.parse(line)
    rescue JSON::ParserError
      # fleet-telemetry mixes startup/error logs with record output on stdout.
      # Skip anything that isn't a JSON record.
      next
    end

    post(http, line)
  end
end
