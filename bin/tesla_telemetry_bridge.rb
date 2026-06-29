#!/usr/bin/env ruby
# Tails the fleet-telemetry feed file and POSTs each vehicle-data JSON
# record to the Rails webhook. Runs under systemd on prod; restart it after
# rotating the feed file. See _scripts/tesla/fleet_telemetry/SETUP.md.
#
# Fleet-telemetry's stdout mixes vehicle records with operational noise:
# socket connect/disconnect lifecycle events, request logs, alert records,
# etc. Forwarding the noise was polluting the telemetry cache (ConnectionID,
# remote_ip, txid, alert payloads all deep-merging into `current`). We
# filter here so Rails only sees actual telemetry data.

require "json"
require "net/http"
require "uri"

FEED    = ENV.fetch("TELEMETRY_FEED", "/var/log/tesla-telemetry/feed.jsonl")
WEBHOOK = URI(ENV.fetch("TELEMETRY_WEBHOOK", "http://localhost:3141/webhooks/tesla_telemetry"))

# Whitelist of known Tesla vehicle-data telemetry fields. Mirrors the keys
# requested in app/service/tesla_service.rb#fields. A record is forwarded
# only if at least one of these keys appears (at the top level OR inside a
# nested "data" envelope) — that's the unambiguous signal of real vehicle
# data, as distinct from bridge/fleet-telemetry operational noise.
VEHICLE_FIELDS = %w[
  VehicleName
  VehicleSpeed
  ChargeState
  Odometer
  Location
  GpsState
  GpsHeading
  DoorState
  Locked
  FdWindow
  FpWindow
  RdWindow
  RpWindow
  TpmsPressureFl
  TpmsPressureFr
  TpmsPressureRl
  TpmsPressureRr
  InsideTemp
  OutsideTemp
  HvacPower
  MilesToArrival
  MinutesToArrival
  RouteLine
  OriginLocation
  DestinationLocation
].freeze

NOISE_MSG_VALUES = %w[socket_connected socket_disconnected request_start request_end].freeze

def vehicle_record?(record)
  return false unless record.is_a?(Hash)
  return false if NOISE_MSG_VALUES.include?(record["msg"])
  return false if record["txtype"] == "alerts"

  candidate_keys = record.keys + (record["data"].is_a?(Hash) ? record["data"].keys : [])
  candidate_keys.any? { |k| VEHICLE_FIELDS.include?(k) }
end

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

IO.popen(["tail", "-n", "0", "-F", FEED], "r") { |io|
  io.each_line { |line|
    line.strip!
    next if line.empty?

    begin
      record = JSON.parse(line)
    rescue JSON::ParserError
      # fleet-telemetry mixes startup/error logs with record output on stdout.
      # Skip anything that isn't JSON.
      next
    end

    next unless vehicle_record?(record)

    post(http, line)
  }
}
