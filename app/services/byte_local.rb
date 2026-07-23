require "net/http"
require "json"
require "socket"
require "uri"

# Rails → local Mac server bridge for Byte. Keeps the HTTP call site
# in one place so we can swap transports (worker, queue, tunnel) without
# touching the controller.
#
# Config via env:
#   BYTE_LOCAL_URL     — base URL of the Mac server (default localhost:8788)
#   BYTE_LOCAL_SECRET  — shared secret; sent as X-Byte-Secret header
module ByteLocal
  module_function

  DEFAULT_URL = "http://localhost:8788".freeze
  DEFAULT_PORT = 8788
  TIMEOUT_SECONDS = 5

  # Resolution order:
  # 1. `BYTE_LOCAL_URL` — explicit override for staging / tunnels
  # 2. `DataStorage[:local_ip]` — auto-detected Mac public IP, refreshed by
  #    the `webhooks/local_ping` job (same source Tesla uses; requires port
  #    #{DEFAULT_PORT} forwarded on the router to the Mac's LAN IP)
  # 3. `localhost:8788` — dev fallback (Rails and the Mac server share a host)
  def base_url
    return ENV["BYTE_LOCAL_URL"] if ENV["BYTE_LOCAL_URL"].present?

    ip = ::DataStorage[:local_ip]
    return "http://#{ip}:#{DEFAULT_PORT}" if ip.present?

    DEFAULT_URL
  end

  def secret
    ENV.fetch("BYTE_LOCAL_SECRET", "")
  end

  # Kick off downstream handling for a user-sent message. Non-blocking as
  # far as the caller cares: the local server is expected to accept the
  # request quickly and stream a response back via /webhooks/byte.
  def deliver(message)
    uri = URI.join(base_url, "/byte/incoming")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)
    req.body = JSON.generate({
      message_id: message.id,
      user_id:    message.user_id,
      body:       message.body,
      metadata:   message.metadata,
    })

    Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http|
      http.request(req)
    }
  rescue => e
    Rails.logger.warn("[Byte] local deliver failed: #{e.class}: #{e.message}")
    nil
  end

  def valid_secret?(header_value)
    expected = secret
    return true if expected.empty? && Rails.env.development?

    header_value.present? && ActiveSupport::SecurityUtils.secure_compare(header_value.to_s, expected)
  end

  # =========================================================================
  # Connectivity diagnostics.
  #
  # Runs every layer of the Rails → Mac path in order, prints a labelled
  # report, and appends a best-guess diagnosis based on the first failing
  # check. Returns the structured result so it's also programmable.
  #
  #   ByteLocal.ping
  # =========================================================================

  def ping
    checks = [
      check_secret,
      check_env_url,
      check_local_ip,
      check_base_url,
      check_tcp,
      check_health,
    ]
    diagnosis = diagnose(checks)
    print_report(checks, diagnosis)
    { checks: checks, diagnosis: diagnosis }
  end

  # ---------- individual checks ----------

  def check_secret
    s = secret
    if s.empty?
      { name: "BYTE_LOCAL_SECRET", status: :fail, note: "unset — server will reject every request as 401" }
    else
      { name: "BYTE_LOCAL_SECRET", status: :pass, value: "#{s.length} chars" }
    end
  end

  def check_env_url
    v = ENV["BYTE_LOCAL_URL"]
    if v.nil? || v.empty?
      { name: "BYTE_LOCAL_URL (env override)", status: :pass, value: "unset (auto-detect)" }
    elsif v.include?("localhost") || v.include?("127.0.0.1")
      { name: "BYTE_LOCAL_URL (env override)", status: :warn, value: v, note: "points at loopback; in prod this reaches the web server, not the Mac" }
    else
      { name: "BYTE_LOCAL_URL (env override)", status: :pass, value: v }
    end
  end

  def check_local_ip
    ip = ::DataStorage[:local_ip]
    if ip.blank?
      { name: "DataStorage[:local_ip]", status: :fail, note: "unset — Mac's local_ping never landed. Confirm the local_ping worker is running on the Mac and hitting /webhooks/local_ping as User.me." }
    elsif ip !~ /\A\d{1,3}(\.\d{1,3}){3}\z/
      { name: "DataStorage[:local_ip]", status: :warn, value: ip, note: "doesn't look like an IPv4 address" }
    else
      { name: "DataStorage[:local_ip]", status: :pass, value: ip }
    end
  end

  def check_base_url
    { name: "Resolved base_url", status: :pass, value: base_url }
  rescue => e
    { name: "Resolved base_url", status: :fail, note: "#{e.class}: #{e.message}" }
  end

  def check_tcp
    uri = URI.parse(base_url)
    started = Time.current
    Socket.tcp(uri.hostname, uri.port, connect_timeout: TIMEOUT_SECONDS) { }
    { name: "TCP #{uri.hostname}:#{uri.port}", status: :pass, value: "#{((Time.current - started) * 1000).round}ms" }
  rescue => e
    { name: "TCP #{uri.hostname}:#{uri.port}", status: :fail, note: "#{e.class}: #{e.message}" }
  end

  def check_health
    uri = URI.join(base_url, "/health")
    res = Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |h| h.request(Net::HTTP::Get.new(uri)) }

    body = res.body.to_s
    if res.code == "200" && body.include?("\"ok\":true")
      { name: "GET /health", status: :pass, value: body.strip }
    elsif res.code == "200"
      { name: "GET /health", status: :warn, value: "#{res.code} #{body[0, 120]}", note: "200 OK but response doesn't look like Byte's server — some other service may be answering on that port" }
    else
      { name: "GET /health", status: :warn, value: "#{res.code} #{body[0, 120]}", note: "non-200 response" }
    end
  rescue => e
    { name: "GET /health", status: :fail, note: "#{e.class}: #{e.message}" }
  end

  # ---------- diagnosis ----------

  # Look for the first failing check and translate the specific failure into
  # a targeted next-action hint. Falls through to a generic hint if nothing
  # specific matches.
  def diagnose(checks)
    fail_or_warn = checks.detect { |c| c[:status] == :fail } ||
                   checks.detect { |c| c[:status] == :warn }
    return "All checks passed — connectivity is healthy." if fail_or_warn.nil?

    note = fail_or_warn[:note].to_s
    case fail_or_warn[:name]
    when "BYTE_LOCAL_SECRET"
      "Set BYTE_LOCAL_SECRET in the Rails env to match the value the Mac server reads. Both processes must share it."
    when "BYTE_LOCAL_URL (env override)"
      "Remove BYTE_LOCAL_URL from the env so DataStorage[:local_ip] is used. In prod, localhost is the web server, not the Mac."
    when "DataStorage[:local_ip]"
      "Confirm the local_ping worker on the Mac is running and hitting POST /webhooks/local_ping with an authenticated session for User.me."
    else
      case note
      when /ECONNREFUSED/
        "TCP-level rejection: server isn't listening on that port. Confirm `ruby _scripts/byte/server.rb` is running on the Mac and bound to 0.0.0.0 (check `lsof -iTCP:#{DEFAULT_PORT} -sTCP:LISTEN`)."
      when /OpenTimeout|ETIMEDOUT|EHOSTUNREACH/
        "Route blocked between prod and the Mac. Verify: (a) router forward for #{DEFAULT_PORT} → LAN IP:#{DEFAULT_PORT}, (b) router source-IP ACL matches prod's egress IP, (c) macOS Application Firewall isn't blocking the ruby process."
      when /getaddrinfo|SocketError/
        "Hostname resolution failed. If BYTE_LOCAL_URL is set to a hostname, confirm DNS resolves it from the prod host."
      when /401|unauthorized/i
        "Server up, secret mismatch. BYTE_LOCAL_SECRET on Rails must match what the Mac server reads."
      else
        "First failing step: #{fail_or_warn[:name]} — #{note.presence || 'inspect the check result for detail'}."
      end
    end
  end

  # ---------- output ----------

  def print_report(checks, diagnosis)
    puts
    puts "== Byte connectivity check =="
    checks.each { |c|
      marker = case c[:status]
      when :pass then "\e[32m✓\e[0m"
      when :warn then "\e[33m!\e[0m"
      when :fail then "\e[31m✗\e[0m"
      end
      line = "  #{marker} #{c[:name]}"
      line << " — #{c[:value]}" if c[:value]
      line << "  (#{c[:note]})" if c[:note]
      puts line
    }
    puts "---"
    puts "Diagnosis: #{diagnosis}"
    puts
  end
end
