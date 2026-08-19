require "net/http"
require "json"
require "socket"
require "timeout"
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

  # Named things the Mac can do, and what to tell Buddy each one is for.
  #
  # This hash is the WHOLE registry as far as Rails is concerned: it builds the
  # `mac_command` tool's enum and its description at registration time, so
  # nothing ever asks the Mac what it can do. Discovering the list over HTTP
  # would put a network round trip — and a machine that might be asleep — in
  # front of every turn, including the overwhelming majority that never touch it.
  #
  # What actually RUNS lives on the Mac (~/code/Byte/mac_commands.rb), and only
  # the NAME crosses the wire. That server is port-forwarded from the internet,
  # so an endpoint taking a shell string would be remote code execution behind a
  # shared secret. Adding a command means editing both files; a name that exists
  # on only one side is inert rather than dangerous.
  MAC_COMMANDS = {
    dark_monitors: "Put the Mac's displays to sleep - 'dark monitors', 'turn the monitors off', " \
                   "'kill the screens'. The machine keeps running; only the displays go dark.",
    mac_ping:      "Check the Mac is awake and can actually run something. Use when they ask " \
                   "whether it's up, or when they want to test that this tool works. Changes nothing.",
  }.freeze

  # Hard ceiling on a Mac command, wall clock, including connect. Five seconds
  # is far longer than any of these need — they're desk actions that finish in
  # milliseconds — and past that the useful conclusion is "the Mac isn't there",
  # not "wait longer". Buddy is holding a turn open on this, so a slow answer
  # costs the person exactly as much as a missing one.
  COMMAND_TIMEOUT_SECONDS = 5

  # Resolution order:
  # 1. `BYTE_LOCAL_URL` — explicit override for staging / tunnels
  # 2. `DataStorage[:local_ip]` — auto-detected Mac public IP, refreshed by
  #    the `webhooks/local_ping` job (same source Tesla uses; requires port
  #    #{DEFAULT_PORT} forwarded on the router to the Mac's LAN IP)
  # 3. `localhost:8788` — dev fallback (Rails and the Mac server share a host)
  def base_url
    env_val = clean_url(ENV["BYTE_LOCAL_URL"])
    return env_val if env_val.present?

    ip = ::DataStorage[:local_ip]
    return "http://#{ip}:#{DEFAULT_PORT}" if ip.present?

    DEFAULT_URL
  end

  # Defensive: strips wrapping quotes and inline `# comments` that
  # sometimes leak in via poorly-parsed .env lines. Without this,
  # `BYTE_LOCAL_URL='http://localhost:8788' # LOCAL ONLY` becomes an
  # invalid URI that fails every message with URI::InvalidURIError.
  def clean_url(raw)
    return nil if raw.nil?

    raw.to_s
       .sub(/\s+#.*\z/, "")     # strip trailing " # comment"
       .strip
       .gsub(/\A['"]|['"]\z/, "")  # strip wrapping quotes
       .strip
  end

  def secret
    ENV.fetch("BYTE_LOCAL_SECRET", "")
  end

  # Kick off downstream handling for a user-sent message. Non-blocking as
  # far as the caller cares: the local server is expected to accept the
  # request quickly and stream a response back via /webhooks/byte.
  #
  # `conversation:` carries the per-thread dispatch mode + persisted
  # metadata (bash cwd, claude session id, adopted-session hint) so the
  # Mac can route without a Rails round-trip.
  #
  # NOTE: this is the claude / terminal path ONLY. Buddy used to come through
  # here too, carrying a context snapshot and tool override for the Mac to hand
  # to `claude -p`; it now runs entirely in Rails (Buddy::GPT::Turn) and never
  # reaches the Mac. Do not reintroduce Buddy-specific payload here.
  def deliver(message, conversation: nil)
    uri = URI.join(base_url, "/byte/incoming")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)

    payload = {
      message_id:      message.id,
      user_id:         message.user_id,
      body:            message.body,
      metadata:        message.metadata,
      conversation_id: conversation&.id || message.byte_conversation_id,
      conversation:    conversation ? conversation_payload(conversation) : nil,
      # Images the person attached, as {filename, content_type, url} with a
      # short-lived directly-fetchable URL. The Mac downloads each to a temp
      # file and points the Claude turn at it (Claude Code can Read image
      # files). Empty for the overwhelming majority of turns.
      attachments:     message.model_image_sources,
    }

    req.body = JSON.generate(payload)

    Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http|
      http.request(req)
    }
  rescue => e
    Rails.logger.warn("[Byte] local deliver failed: #{e.class}: #{e.message}")
    nil
  end

  # Run one of MAC_COMMANDS on the Mac and wait for the result.
  #
  # Raises rather than returning nil on every failure path, because the only
  # caller is a Buddy tool: a raise becomes "couldn't do that one" on the
  # activity chip, while a nil would read as success and let Buddy tell someone
  # their monitors are off when the Mac never answered.
  def run_command(name)
    raise "#{name} isn't a Mac command I have" unless MAC_COMMANDS.key?(name.to_s.to_sym)

    uri = URI.join(base_url, "/byte/command")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)
    req.body = JSON.generate({ name: name })

    # Net::HTTP's timeouts are per-phase and read_timeout restarts on every
    # chunk, so a server that trickles can outlive them indefinitely. The outer
    # bound is what actually guarantees the ceiling.
    res = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) {
      Net::HTTP.start(uri.hostname, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: COMMAND_TIMEOUT_SECONDS, read_timeout: COMMAND_TIMEOUT_SECONDS,
      ) { |http| http.request(req) }
    }

    body = JSON.parse(res.body) rescue {}
    raise(body["error"].presence || "the Mac said no (#{res.code})") unless res.is_a?(Net::HTTPSuccess)

    body.symbolize_keys
  rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, SystemCallError, SocketError, IOError => e
    Rails.logger.warn("[Byte] run_command #{name} failed: #{e.class}: #{e.message}")
    raise "couldn't reach the Mac - it may be asleep"
  end

  # Ask the Mac to enumerate the Claude Code sessions on disk for a given
  # conversation's cwd. Returns the parsed JSON array, or nil if the Mac
  # is unreachable.
  def list_claude_sessions(conversation_id:)
    uri = URI.join(base_url, "/byte/claude_sessions?conversation_id=#{conversation_id.to_i}")
    req = Net::HTTP::Get.new(uri, "X-Byte-Secret" => secret)

    res = Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http| http.request(req) }

    return nil unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body)["sessions"]
  rescue => e
    Rails.logger.warn("[Byte] list_claude_sessions failed: #{e.class}: #{e.message}")
    nil
  end

  # Rails → Mac: point a conversation's shell and Claude turns at a directory.
  #
  # The Mac normally owns cwd (a `!cd` moves it, and the Mac reports back), and
  # this doesn't change that — it's the one case where the decision is made
  # somewhere the Mac can't see: the new-conversation modal on a phone, and
  # `/cd`. Returns false rather than raising when the Mac is asleep; the value
  # is on the conversation record either way and the Mac seeds from it on the
  # next turn.
  def set_cwd(conversation_id:, cwd:)
    uri = URI.join(base_url, "/byte/set_cwd")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)
    req.body = JSON.generate({ conversation_id: conversation_id.to_i, cwd: cwd.to_s })

    res = Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http| http.request(req) }

    res.is_a?(Net::HTTPSuccess)
  rescue => e
    Rails.logger.warn("[Byte] set_cwd failed: #{e.class}: #{e.message}")
    false
  end

  # Rails → Mac: drop a conversation's Claude session so the next turn starts
  # clean. What `/reset` does, without having to send a message to do it.
  #
  # Needed because the session id lives in the Mac's own state file and Rails
  # can't reach it — clearing `claude_session_id` off the conversation record
  # only removes the FALLBACK, and the Mac prefers its own copy.
  #
  # Sending `/reset` as a message instead would race: /byte/incoming answers 202
  # and runs the turn on a thread, so a prompt posted straight after can win and
  # land in the session that was supposed to be gone. This answers before it
  # returns.
  #
  # Returns false rather than raising when the Mac is asleep. The caller's next
  # move is to wait for the Mac either way, and a stale session is a worse turn,
  # not a broken one.
  def reset_claude_session(conversation_id:)
    uri = URI.join(base_url, "/byte/reset_session")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)
    req.body = JSON.generate({ conversation_id: conversation_id.to_i })

    res = Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http| http.request(req) }

    res.is_a?(Net::HTTPSuccess)
  rescue => e
    Rails.logger.warn("[Byte] reset_claude_session failed: #{e.class}: #{e.message}")
    false
  end

  # Is the Mac actually up right now? Used before scheduling work onto it, so a
  # sleeping machine becomes "try again later" rather than a failed message
  # sitting in a thread.
  def awake?
    uri = URI.join(base_url, "/health")
    res = Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http| http.request(Net::HTTP::Get.new(uri)) }

    res.is_a?(Net::HTTPSuccess) && res.body.to_s.include?("\"ok\":true")
  rescue => e
    Rails.logger.warn("[Byte] health check failed: #{e.class}: #{e.message}")
    false
  end

  def conversation_payload(conversation)
    {
      id:       conversation.id,
      mode:     conversation.mode,
      name:     conversation.display_name,
      metadata: conversation.metadata,
    }
  end

  # Rails → Mac: user has decided on an action-request. Mac wakes any
  # PreToolUse hook blocking on that request_id so Claude Code proceeds.
  # The five attributes the Mac needs, read on whatever connection the caller
  # already holds. Split out from the notify below so a caller running this in
  # a detached thread can gather them BEFORE the thread starts.
  def action_decision_payload(action)
    {
      request_id: action.request_id,
      decision:   action.decision,
      state:      action.state,
      kind:       action.kind,
      tool_name:  action.tool_name,
    }
  end

  # Takes the plain hash from `action_decision_payload`, never the record.
  # Touching ActiveRecord here would check out a pooled connection and hold it
  # for the full length of the HTTP call — and this call exists precisely for
  # the case where the Mac is unreachable and it hangs to the timeout.
  def notify_action_decision(payload)
    uri = URI.join(base_url, "/byte/action_decision")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "X-Byte-Secret" => secret)
    req.body = JSON.generate(payload)

    Net::HTTP.start(uri.hostname, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS,
    ) { |http| http.request(req) }
  rescue => e
    Rails.logger.warn("[Byte] notify_action_decision failed: #{e.class}: #{e.message}")
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
        "TCP-level rejection: server isn't listening on that port. Confirm `ruby ~/code/Byte/server.rb` is running on the Mac and bound to 0.0.0.0 (check `lsof -iTCP:#{DEFAULT_PORT} -sTCP:LISTEN`)."
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
