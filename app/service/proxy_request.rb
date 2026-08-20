# Not working?
# Restart modem, router, and computer - in that order
# `updateIp`
# Verify `myip` on laptop matches the port forwarding in `https://192.168.0.1/advancedsetup_advancedportforwarding.html`
# Router: DMZ Hosting → Enable laptop local ip address
# ProxyRequest.local_ping     — one-shot POST to the relay's /test
# ProxyRequest.diagnose       — layered breakdown of WHERE the path is broken
# ProxyRequest.probe          — same walk, structured and silent (the Slack alert uses this)

class ProxyRequest
  PROXY_PORT = 3142
  IPV4       = /\A\d{1,3}(\.\d{1,3}){3}\z/

  def self.local_ping
    Api.post("http://#{DataStorage[:local_ip]}:#{PROXY_PORT}/test")
  end

  RELAY_SEEN_AT_KEY = :tesla_relay_seen_at
  RELAY_LAN_KEY     = :tesla_relay_lan

  # Stamped by the relay process itself (proxy/listener.rb), which is running
  # exactly when the relay is. That makes it the one signal separating "Mac
  # asleep or relay dead" from "Mac fine, router mis-forwarding" — from outside
  # the house those are indistinguishable, both just a dead port.
  def self.record_relay_heartbeat!(lan_ip: nil, interface: nil)
    DataStorage[RELAY_SEEN_AT_KEY] = Time.current.to_i
    return if lan_ip.blank?

    DataStorage[RELAY_LAN_KEY] = { ip: lan_ip, interface: interface }
  end

  def self.relay_last_seen_at
    raw = DataStorage[RELAY_SEEN_AT_KEY]
    return nil if raw.blank?

    Time.zone.at(raw.to_i)
  end

  # Where the relay says it currently lives. The router has to be forwarding to
  # THIS address; when a NIC drops off, the Mac quietly moves to another one and
  # the old target goes dead while the relay itself never falters.
  def self.relay_lan
    DataStorage[RELAY_LAN_KEY].presence&.with_indifferent_access
  end

  # Walks the prod → public IP → router port-forward → Ruby relay path one layer
  # at a time, stops at the first fatal failure, and prints exactly what to check
  # for that layer. Run from a prod console when a ":satellite: proxy unreachable"
  # alert fires — it turns "unreachable" into "unreachable AT this step".
  def self.diagnose = new.diagnose

  # The same walk with no narration, returning the structured result. This is
  # what TeslaErrorClassifier embeds in the alert, so the Slack post names the
  # broken layer instead of listing every layer that could be broken.
  def self.probe = new.probe

  # `fatal` decides whether a failed layer ends the walk. ICMP is deliberately
  # NOT fatal: plenty of routers drop inbound ping outright, so treating it as
  # fatal aborted the walk at layer 2 and blamed the pre-router path whenever
  # ICMP was merely filtered — while the real break sat one layer down at TCP.
  # It stays in the walk as corroboration for the TCP remediation instead.
  # Each signal gets a tolerance derived from its own measured cadence rather
  # than one shared guess: local_ping arrives every 5 min from the Desktop's
  # cron, the relay every 2 min from proxy/listener.rb. Three missed check-ins
  # is the bar for calling a signal dead — loose enough to ride out a hiccup,
  # tight enough that a Mac which went to sleep four minutes ago shows up in the
  # very alert that reports it, instead of still looking healthy for a quarter
  # of an hour. A single shared 15 min gave the relay 7 misses and made it
  # useless for exactly the case it was added to catch.
  HOUSE_STALE_AFTER = 15.minutes
  RELAY_STALE_AFTER = 6.minutes

  STEPS = [
    { key: :house, label: "home network checked in (informational)", run: :check_house, fatal: false },
    { key: :relay, label: "relay process checked in (informational)", run: :check_relay, fatal: false },
    { key: :config, label: "local_ip is configured", run: :check_config, fatal: true },
    { key: :ping, label: "host answers ICMP ping (informational)", run: :check_ping, fatal: false },
    { key: :tcp, label: "port #{PROXY_PORT} accepts a TCP connection", run: :check_tcp, fatal: true },
    { key: :http, label: "Ruby relay answers /test", run: :check_http, fatal: true },
  ].freeze

  HEALTHY_NEXT_STEPS = [
    "• Go signer down → on the Mac:",
    "    launchctl kickstart -k gui/$UID/com.ardesian.tesla-go-proxy",
    "• Token expired  → re-auth (see TeslaErrorClassifier :auth_refresh_failed)",
  ].freeze

  def probe
    @ip = DataStorage[:local_ip].to_s
    @results = {}
    failed = nil

    STEPS.each { |step|
      @results[step[:key]] = send(step[:run])
      next if @results[step[:key]][:ok] || !step[:fatal]

      failed = step
      break
    }

    {
      ip:          @ip.presence,
      ok:          failed.nil?,
      failed_at:   failed && failed[:key],
      layers:      STEPS.filter_map { |step| layer(step) },
      remediation: (failed ? send(:"fix_#{failed[:key]}", @results[failed[:key]]) : HEALTHY_NEXT_STEPS),
    }
  end

  def layer(step)
    result = @results[step[:key]]
    return nil if result.nil?

    { key: step[:key], label: step[:label], ok: result[:ok], fatal: step[:fatal], detail: result[:detail] }
  end

  def diagnose
    result = probe
    puts
    puts bold("Tesla proxy reachability — #{result[:ip] || "UNSET"}:#{PROXY_PORT}")
    puts("─" * 64)
    result[:layers].each { |l| puts "  #{mark(l)} #{l[:label]}  #{dim(l[:detail])}" }
    puts

    if result[:ok]
      puts green("  ✓ All layers healthy — the relay is reachable end-to-end.")
      puts dim("    If a real command still fails, the break is PAST the relay:")
      result[:remediation].each { |line| puts dim("    #{line}") }
    else
      puts yellow("    ↳ What to check:")
      result[:remediation].each { |line| puts "      #{line}" }
      puts
    end

    result
  end

  def mark(layer)
    return green("✓") if layer[:ok]
    return yellow("!") unless layer[:fatal]

    red("✗")
  end

  # ── Layer checks ────────────────────────────────────────────────────────
  # Each returns { ok:, detail:, error: } so the caller can branch on the
  # concrete exception (EHOSTUNREACH vs ECONNREFUSED vs timeout tell very
  # different stories about which knob to turn).

  # Answers "is anything home?" without touching the network, which is the one
  # question the walk itself can't settle: every network layer failing looks the
  # same whether the house is offline or merely mis-forwarded.
  def check_house = checkin(LocalIpManager.last_seen_at, "/webhooks/local_ping", HOUSE_STALE_AFTER)

  def check_relay
    result = checkin(self.class.relay_last_seen_at, "relay heartbeat", RELAY_STALE_AFTER)
    lan = self.class.relay_lan
    return result if lan.blank? || lan[:ip].blank?

    result.merge(detail: "#{result[:detail]} from #{lan[:ip]} (#{lan[:interface]})")
  end

  def checkin(at, label, stale_after)
    return { ok: false, detail: "no #{label} ever recorded" } if at.nil?

    age = Time.current - at
    return { ok: true, detail: "#{time_ago(age)} ago" } if age <= stale_after

    { ok: false, detail: "#{time_ago(age)} ago — stale" }
  end

  def time_ago(seconds)
    return "#{seconds.round}s" if seconds < 60
    return "#{(seconds / 60).round}m" if seconds < 3600
    return "#{(seconds / 3600).round}h" if seconds < 86_400

    "#{(seconds / 86_400).round}d"
  end

  def check_config
    return { ok: false, detail: "DataStorage[:local_ip] is blank" } if @ip.blank?
    return { ok: false, detail: "not an IPv4 address: #{@ip.inspect}" } unless @ip.match?(IPV4)

    { ok: true, detail: @ip }
  end

  def check_ping
    ok = ping_host(@ip)
    { ok: ok, detail: ok ? "ICMP reply received" : "no ICMP reply (routers often filter it — not conclusive)" }
  end

  def check_tcp
    err = tcp_error(@ip, PROXY_PORT)
    return { ok: true, detail: "port open" } if err.nil?

    { ok: false, detail: "#{err.class}: #{err.message}", error: err }
  end

  def check_http
    body = http_test(@ip, PROXY_PORT)
    ok = body.to_s.include?("success")
    { ok: ok, detail: ok ? "relay OK (#{body.to_s.truncate(60)})" : "unexpected: #{body.to_s.truncate(120)}" }
  end

  # ── Network primitives (stubbed in specs) ─────────────────────────────────

  def ping_host(ip)
    system("ping", "-c", "1", "-W", "2", ip, out: File::NULL, err: File::NULL)
  end

  def tcp_error(ip, port)
    Socket.tcp(ip, port, connect_timeout: 3, &:close)
    nil
  rescue StandardError => e
    e
  end

  def http_test(ip, port)
    uri = URI("http://#{ip}:#{port}/test")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 5) { |http|
      http.post(uri.path, "").body
    }
  rescue StandardError => e
    "ERROR: #{e.class}: #{e.message}"
  end

  # ── Per-layer remediation ─────────────────────────────────────────────────

  def fix_config(_result)
    heartbeat_lines + [
      "DataStorage[:local_ip] isn't a usable IP — nothing downstream can work.",
      "• Set it from the Mac's public IP (LocalIpManager pushes it via duckdns).",
      "• On the Mac: curl ifconfig.me  → that value is what belongs here.",
    ]
  end

  def fix_tcp(result)
    name = result[:error]&.class&.name.to_s
    lines = (
      if name == "Errno::EHOSTUNREACH"
        tcp_no_route_fix
      elsif name == "Errno::ECONNREFUSED"
        tcp_refused_fix
      elsif name.in?(["Errno::ETIMEDOUT", "IO::TimeoutError"])
        tcp_timeout_fix
      else
        tcp_generic_fix(result)
      end
    )

    heartbeat_lines + relay_alive_lines + lines + stale_ip_lines
  end

  # The failure this names: the relay never went down, but the interface holding
  # the forwarded address did. From prod that is indistinguishable from a dead
  # port-forward, so it reads as a router problem while the router is fine — and
  # a USB NIC that hangs on the bus produces exactly this shape.
  def relay_alive_lines
    relay = @results[:relay]
    return [] if relay.nil? || !relay[:ok]

    lan = self.class.relay_lan
    return [] if lan.blank? || lan[:ip].blank?

    [
      "The relay is still checking in from #{lan[:ip]} (#{lan[:interface]}) — it never went",
      "down. So the relay is healthy and the FORWARDED ADDRESS is the fault line.",
      "• #{PROXY_PORT} must forward to #{lan[:ip]}, which is where the relay is right now.",
      "• If it already does, the interface behind it dropped off. See the USB note below.",
    ]
  end

  # Worth its own block because it is not intuitive and it is not optional: a
  # hung USB NIC keeps its link LED lit and keeps the switch port happy, so
  # every cable-level check passes while the host sees nothing at all.
  def usb_cycle_lines
    [
      "If the Mac reaches the LAN on a USB ethernet adapter or dock, POWER-CYCLE IT:",
      "• Unplug the adapter/dock from the Mac for ~30s, then reconnect.",
      "• Re-seating the ETHERNET cable does nothing — the adapter has to lose power.",
      "• Confirm it came back: ioreg -p IOUSB -w 0 | grep -i lan   (and `ifconfig -l`).",
      "• Then re-check that the forward still targets the address it came back on.",
    ]
  end

  # A missing check-in outranks every port-forward theory, so it leads. The PAIR
  # is what discriminates: either signal alone is ambiguous, but together they
  # separate "nothing is home" from "the house is up and this Mac isn't" — the
  # split the network walk cannot make, since both present as a dead port.
  def heartbeat_lines
    house = @results[:house]
    relay = @results[:relay]
    return [] if house.nil? || relay.nil?
    return [] if house[:ok] && relay[:ok]
    return both_silent_lines if !house[:ok] && !relay[:ok]
    return relay_silent_lines unless relay[:ok]

    house_silent_lines
  end

  def both_silent_lines
    [
      "Nothing has checked in — not the home network, not the relay:",
      "• The house is offline, or #{@ip} stopped being its public address.",
      "• Start at the modem/router. The port-forward is not the story here.",
    ]
  end

  def relay_silent_lines
    [
      "Home network is checking in but the relay is NOT (#{@results[:relay][:detail]}):",
      "• The proxy Mac is asleep/off, or the relay process died. The house is fine.",
      "• Wake the Mac, then: launchctl kickstart -k gui/$UID/com.ardesian.tesla-ruby-relay",
    ]
  end

  def house_silent_lines
    [
      "Relay is checking in but the home network ping is NOT (#{@results[:house][:detail]}):",
      "• The proxy Mac is up, so this is not your outage — but the /webhooks/local_ping",
      "    job died, and DataStorage[:local_ip] goes stale silently from here on.",
    ]
  end

  # The single most common failure, and the subtlest: the router accepts the
  # packet, tries to forward it, and finds nothing at the target LAN IP.
  def tcp_no_route_fix
    [
      "Something answered \"no route to host\" → the router is forwarding #{PROXY_PORT}",
      "to a LAN IP no device currently holds (a dead port-forward / DMZ target).",
      "• Router port-forward / DMZ for #{PROXY_PORT} must target the Mac's CURRENT LAN IP.",
      "• On the Mac, that IP is: ipconfig getifaddr en0",
      "    (or whichever interface `route -n get default` names).",
      "• DHCP-reserve it against the MAC of the interface actually holding it — Wi-Fi",
      "    counts. A dead cable/dock makes the Mac fall back to Wi-Fi silently.",
    ] + usb_cycle_lines
  end

  def tcp_refused_fix
    [
      "Host reachable and the port is forwarded, but nothing is listening on #{PROXY_PORT}",
      "→ the Ruby relay is down. On the Mac:",
      "• launchctl kickstart -k gui/$UID/com.ardesian.tesla-ruby-relay",
      "• Confirm it came back: `lsof -i :#{PROXY_PORT}` shows the listener.",
    ]
  end

  def tcp_timeout_fix
    [
      "Connection timed out (packets silently dropped) → something is filtering #{PROXY_PORT}.",
      "• Router port-forward rule missing/disabled, or a firewall is dropping it.",
      "• macOS firewall on the Mac blocking inbound on #{PROXY_PORT}.",
    ] + usb_cycle_lines
  end

  def tcp_generic_fix(result)
    [
      "TCP connect failed: #{result[:detail]}.",
      "• Network/DNS-level problem reaching #{@ip}:#{PROXY_PORT}.",
      "• Re-check DataStorage[:local_ip] and the router port-forward.",
    ]
  end

  # Only worth raising when ICMP went unanswered too. A dead port on a host that
  # still answers ping is a forwarding problem; nothing answering at EITHER layer
  # points further upstream, at whether we're even aimed at the right address.
  def stale_ip_lines
    return [] if @results[:ping] && @results[:ping][:ok]

    [
      "ICMP went unanswered as well, so confirm the address itself:",
      "• On the Mac: curl ifconfig.me — must equal #{@ip}, else DataStorage[:local_ip] is stale.",
      "• If it matches and inbound still fails entirely → possible ISP CGNAT.",
    ]
  end

  def fix_http(result)
    [
      "TCP opened but /test didn't return success (#{result[:detail]}).",
      "The relay socket answered but the app behind it is wedged.",
      "• Kickstart BOTH launchd jobs on the Mac:",
      "    launchctl kickstart -k gui/$UID/com.ardesian.tesla-ruby-relay",
      "    launchctl kickstart -k gui/$UID/com.ardesian.tesla-go-proxy",
      "• Check the relay's output/log for a crash on startup.",
    ]
  end

  # ── Tiny color helpers (prod console over SSH renders ANSI fine) ───────────
  def bold(s)   = "\e[1m#{s}\e[0m"
  def green(s)  = "\e[32m#{s}\e[0m"
  def red(s)    = "\e[31m#{s}\e[0m"
  def yellow(s) = "\e[33m#{s}\e[0m"
  def dim(s)    = "\e[90m#{s}\e[0m"

  # ── Original passthrough proxy (unchanged) ────────────────────────────────

  def self.execute(data)
    new.execute(data)
  end

  def execute(data)
    data = data.with_indifferent_access
    @method = data[:method]&.downcase&.to_sym || :get
    @url = data[:url]
    @params = data[:params] || {}
    @headers = data[:headers] || {}

    @response = @method.in?([:get, :delete]) ? request_with_header_params : request_with_payload

    json
  end

  def request_with_header_params
    RestClient::Request.execute(
      method:  @method,
      url:     @url,
      headers: @headers.merge(params: @params),
    )
  end

  def request_with_payload
    RestClient::Request.execute(
      method:  @method,
      url:     @url,
      payload: @params.to_json,
      headers: @headers,
    )
  end

  def json
    JSON.parse(@response.body)
  rescue JSON::ParserError
    @response
  end
end
