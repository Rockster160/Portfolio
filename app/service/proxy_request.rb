# Not working?
# Restart modem, router, and computer - in that order
# `updateIp`
# Verify `myip` on laptop matches the port forwarding in `https://192.168.0.1/advancedsetup_advancedportforwarding.html`
# Router: DMZ Hosting → Enable laptop local ip address
# ProxyRequest.local_ping     — one-shot POST to the relay's /test
# ProxyRequest.diagnose       — layered breakdown of WHERE the path is broken

class ProxyRequest
  PROXY_PORT = 3142
  IPV4       = /\A\d{1,3}(\.\d{1,3}){3}\z/

  def self.local_ping
    Api.post("http://#{DataStorage[:local_ip]}:#{PROXY_PORT}/test")
  end

  # Walks the prod → public IP → router port-forward → Ruby relay path one layer
  # at a time, stops at the first failure, and prints exactly what to check for
  # that layer. Run from a prod console when a ":satellite: proxy unreachable"
  # alert fires — it turns "unreachable" into "unreachable AT this step".
  def self.diagnose = new.diagnose

  STEPS = [
    { key: :config, label: "local_ip is configured",          run: :check_config },
    { key: :ping,   label: "host answers ICMP ping",           run: :check_ping   },
    { key: :tcp,    label: "port #{PROXY_PORT} accepts a TCP connection", run: :check_tcp },
    { key: :http,   label: "Ruby relay answers /test",         run: :check_http   },
  ].freeze

  def diagnose
    @ip = DataStorage[:local_ip].to_s
    puts
    puts bold("Tesla proxy reachability — #{@ip.presence || 'UNSET'}:#{PROXY_PORT}")
    puts("─" * 64)

    STEPS.each do |step|
      result = send(step[:run])
      puts "  #{result[:ok] ? green('✓') : red('✗')} #{step[:label]}  #{dim(result[:detail])}"
      next if result[:ok]

      print_remediation(step, result)
      return { ok: false, failed_at: step[:key], detail: result[:detail] }
    end

    puts
    puts green("  ✓ All layers healthy — the relay is reachable end-to-end.")
    puts dim("    If a real command still fails, the break is PAST the relay:")
    puts dim("    • Go signer down → on the Mac: launchctl kickstart -k gui/$UID/com.ardesian.tesla-go-proxy")
    puts dim("    • Token expired  → re-auth (see TeslaErrorClassifier :auth_refresh_failed)")
    { ok: true, failed_at: nil }
  end

  # ── Layer checks ────────────────────────────────────────────────────────
  # Each returns { ok:, detail:, error: } so the caller can branch on the
  # concrete exception (EHOSTUNREACH vs ECONNREFUSED vs timeout tell very
  # different stories about which knob to turn).

  def check_config
    return { ok: false, detail: "DataStorage[:local_ip] is blank" } if @ip.blank?
    return { ok: false, detail: "not an IPv4 address: #{@ip.inspect}" } unless @ip.match?(IPV4)

    { ok: true, detail: @ip }
  end

  def check_ping
    ok = ping_host(@ip)
    { ok: ok, detail: ok ? "ICMP reply received" : "no ICMP reply" }
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

  def print_remediation(step, result)
    puts
    puts yellow("    ↳ What to check:")
    send(:"fix_#{step[:key]}", result).each { |line| puts "      #{line}" }
    puts
  end

  def fix_config(_result)
    [
      "DataStorage[:local_ip] isn't a usable IP — nothing downstream can work.",
      "• Set it from the Mac's public IP (LocalIpManager pushes it via duckdns).",
      "• On the Mac: curl ifconfig.me  → that value is what belongs here.",
    ]
  end

  def fix_ping(_result)
    [
      "The public IP doesn't answer at all — the break is before the router.",
      "• Home Mac / router off or off-network → power-cycle, then retry.",
      "• Public IP changed and DataStorage[:local_ip] is stale:",
      "    compare it to `curl ifconfig.me` on the Mac; update if different.",
      "• If it flipped and inbound now fails entirely → possible ISP CGNAT.",
    ]
  end

  def fix_tcp(result)
    name = result[:error]&.class&.name.to_s
    return tcp_no_route_fix if name == "Errno::EHOSTUNREACH"
    return tcp_refused_fix  if name == "Errno::ECONNREFUSED"
    return tcp_timeout_fix  if name.in?(["Errno::ETIMEDOUT", "IO::TimeoutError"])

    tcp_generic_fix(result)
  end

  # Ping worked but the port didn't — the single most common failure, and the
  # subtlest. The router accepts the packet, tries to forward it, and finds
  # nothing at the target LAN IP.
  def tcp_no_route_fix
    [
      "Ping worked but the port didn't → the router is forwarding #{PROXY_PORT} to a",
      "LAN IP no device currently holds (a dead port-forward / DMZ target).",
      "• Router port-forward / DMZ for #{PROXY_PORT} must target the Mac's CURRENT LAN IP.",
      "• DHCP-reserve that IP to the Mac's WIRED adapter MAC (not a random Wi-Fi MAC).",
      "• On the Mac: `ifconfig` — the wired interface must be `status: active` + have an inet.",
      "    `media: none` = dead cable/adapter/dock; the Mac silently fell back to Wi-Fi.",
    ]
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
    ]
  end

  def tcp_generic_fix(result)
    [
      "TCP connect failed: #{result[:detail]}.",
      "• Network/DNS-level problem reaching #{@ip}:#{PROXY_PORT}.",
      "• Re-check DataStorage[:local_ip] and the router port-forward.",
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
