# Maps a Tesla exception to one of a handful of recognized failure modes,
# each with a tailored Slack message. Replaces the old single
# TeslaControl::SLACK_ERROR_HINTS blob — point of that change is that future-
# me reading a Slack post on the road can tell from one glance which knob to
# turn instead of triaging a generic checklist.
module TeslaErrorClassifier
  module_function

  PROXY_UNREACHABLE_CLASSES = [
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    SocketError,
    RestClient::ServerBrokeConnection,
    RestClient::Exceptions::OpenTimeout,
    RestClient::Exceptions::ReadTimeout,
  ].freeze

  # Returns one of: :proxy_unreachable, :auth_refresh_failed,
  # :vehicle_asleep, :bad_request, :tesla_5xx, :unknown
  def classify(exception)
    return :proxy_unreachable if PROXY_UNREACHABLE_CLASSES.any? { |k| exception.is_a?(k) }
    return :auth_refresh_failed if exception.is_a?(RestClient::Unauthorized)
    return :bad_request if exception.is_a?(RestClient::BadRequest)
    return :bad_request if exception.is_a?(RestClient::UnprocessableEntity)
    return :vehicle_asleep if exception.is_a?(RestClient::RequestTimeout)

    if exception.is_a?(RestClient::ExceptionWithResponse) && exception.respond_to?(:response)
      code = exception.response&.code.to_i
      return :tesla_5xx if (500..599).cover?(code) && code != 500
      return :tesla_5xx if code == 500 && !tesla_500_means_asleep?(exception)
      return :vehicle_asleep if code == 500 && tesla_500_means_asleep?(exception)
    end

    :unknown
  end

  def tesla_500_means_asleep?(exception)
    body = exception.response&.body.to_s
    return false if body.blank?

    body.include?("vehicle is offline or asleep")
  rescue StandardError
    false
  end

  # Render the Slack message for `exception` raised at `where` (a short
  # caller-supplied label, e.g. "Proxy Command Error" or "Vehicle Data Error").
  # `toggle_link` is a pre-rendered "mute" link from TeslaSwitch, embedded so
  # the user can one-tap silence Tesla while traveling.
  def slack_message(exception, where:, toggle_link:)
    category = classify(exception)
    [
      header(category, where),
      MESSAGES.fetch(category).call(exception, where),
      (proxy_diagnosis_block if category == :proxy_unreachable),
      footer(toggle_link),
    ].compact.join("\n")
  end

  def header(category, where)
    label = HEADERS.fetch(category)
    "*#{label}* — `#{where}`"
  end

  def footer(toggle_link)
    "_Mute (e.g. traveling):_ #{toggle_link}"
  end

  HEADERS = {
    proxy_unreachable:   ":satellite: Tesla home proxy unreachable",
    auth_refresh_failed: ":key: Tesla token refresh failed",
    vehicle_asleep:      ":sleeping: Tesla vehicle wouldn't wake",
    bad_request:         ":warning: Tesla rejected the request",
    tesla_5xx:           ":cloud: Tesla server error",
    unknown:             ":bangbang: Tesla error",
  }.freeze

  # What the exception class alone proves. This is the strongest signal in the
  # whole alert and the old message threw it away: it printed the class, then a
  # fixed four-item checklist led by the two causes that class had already ruled
  # out. Working that list top-down missed every time, because "no route to
  # host" is a reply from something on the path — a sleeping Mac and a crashed
  # relay are the two things that cannot produce it.
  PROXY_VERDICTS = {
    "Errno::ECONNREFUSED"                 => [
      "The path works end-to-end and the Mac *actively refused* the connection.",
      "→ Nothing is listening on 3142: the Ruby relay is down. The Mac itself is fine.",
    ],
    "Errno::EHOSTUNREACH"                 => [
      "Something on the path replied *\"no route to host\"*.",
      "→ The router could not deliver to the LAN IP it forwards 3142 to: either nothing",
      "   holds that address (dead port-forward / DMZ target), or the machine there is",
      "   asleep or off and never answered ARP.",
      "→ Rules OUT a crashed relay on a *live* Mac — that would refuse, not go unreachable.",
      "→ The relay check-in below separates the two.",
    ],
    "Errno::ENETUNREACH"                  => [
      "No route to the network at all — prod couldn't even get a packet out toward it.",
      "→ Look at prod's own egress, or at whether `local_ip` is a routable address.",
    ],
    "Errno::ETIMEDOUT"                    => [
      "Nothing answered at all — the packets were silently dropped.",
      "→ Mac powered off, the port-forward rule is missing/disabled, or a firewall ate it.",
    ],
    "RestClient::Exceptions::OpenTimeout" => [
      "The TCP handshake never completed — silently dropped, nothing answered.",
      "→ Mac powered off, the port-forward rule is missing/disabled, or a firewall ate it.",
    ],
    "RestClient::Exceptions::ReadTimeout" => [
      "The socket opened but the relay never sent a response body.",
      "→ The relay is listening but wedged — the break is the app, not the network.",
    ],
    "RestClient::ServerBrokeConnection"   => [
      "The relay accepted the connection and then dropped it mid-response.",
      "→ The relay is listening but crashing on the request — check its log, not the router.",
    ],
    "SocketError"                         => [
      "The address never resolved.",
      "→ A DNS/name problem, not a home-network one.",
    ],
  }.freeze

  # Matched through the ancestry so a subclass of a mapped error still reads
  # straight instead of falling through to the unmapped branch.
  def proxy_verdict(exception)
    exception.class.ancestors.each { |klass|
      lines = PROXY_VERDICTS[klass.name]
      return lines if lines
    }

    nil
  end

  # Runs the real reachability walk at alert time, so the post names the layer
  # that is actually broken rather than every layer that could be. Wrapped
  # because a probe that blows up must never cost us the alert it rode in on.
  def proxy_diagnosis_block
    result = ::ProxyRequest.probe
    [
      "",
      "*Live probe — #{result[:ip] || "local_ip UNSET"}:#{::ProxyRequest::PROXY_PORT}*",
      "```",
      *result[:layers].map { |layer| "#{layer_mark(layer)} #{layer[:label]} — #{layer[:detail]}" },
      "```",
      (result[:ok] ? "*All layers healthy* — the break is past the relay:" : "*Fix (broken at `#{result[:failed_at]}`):*"),
      *result[:remediation],
    ].join("\n")
  rescue StandardError => e
    "\n_Live probe failed to run: `#{e.class}: #{e.message.to_s[0..120]}`_"
  end

  def layer_mark(layer)
    return "✓" if layer[:ok]
    return "!" unless layer[:fatal]

    "✗"
  end

  MESSAGES = {
    proxy_unreachable:   ->(exc, _where) {
      verdict = proxy_verdict(exc) || [
        "Unmapped error class — add it to `PROXY_VERDICTS` so the next alert reads straight.",
      ]
      [
        "Couldn't reach the home Mac proxies at `#{DataStorage[:local_ip]}:#{::ProxyRequest::PROXY_PORT}`.",
        "`#{exc.class}: #{exc.message.to_s[0..160]}`",
        "",
        "*What the error class proves:*",
        *verdict,
      ].join("\n")
    },
    auth_refresh_failed: ->(exc, _where) {
      <<~MSG.strip
        Access token expired and refresh failed (`#{exc.class}`).

        *Fix:* re-auth from a prod console:
        ```
        Oauth::TeslaApi.me.auth_url
        # open URL → approve → callback sets the new code
        ```
      MSG
    },
    vehicle_asleep:      ->(exc, _where) {
      <<~MSG.strip
        Car stayed asleep through the wake-retry budget.
        `#{exc.class}: #{exc.message.to_s[0..160]}`

        *Likely:* deep sleep / no LTE / parked underground. Often clears on its
        own once the car has signal again. If it persists, open the Tesla app
        to force a connection.
      MSG
    },
    bad_request:         ->(exc, _where) {
      code = exc.respond_to?(:response) ? exc.response&.code : "?"
      body = exc.respond_to?(:response) ? exc.response&.body.to_s[0..400] : nil
      body_block = body.present? ? "```\n#{body}\n```" : nil
      [
        "Tesla returned HTTP `#{code}` — the request body didn't match what Fleet API expects.",
        "`#{exc.class}: #{exc.message.to_s[0..160]}`",
        body_block,
        "*Fix:* compare the `TeslaControl` method args to https://developer.tesla.com/docs/fleet-api — a Tesla schema change usually broke us.",
      ].compact.join("\n")
    },
    tesla_5xx:           ->(exc, _where) {
      code = exc.respond_to?(:response) ? exc.response&.code : "5xx"
      <<~MSG.strip
        Tesla Fleet API returned `#{code}`. Usually transient.

        *Fix:* wait a few minutes and retry. If it persists, check the Tesla
        status page (https://www.tesla.com/support) and our prod
        fleet-telemetry logs (`sudo journalctl -fu fleet-telemetry`).
      MSG
    },
    unknown:             ->(exc, _where) {
      <<~MSG.strip
        Unclassified Tesla failure — please add a category for it in `TeslaErrorClassifier`.
        `#{exc.class}: #{exc.message.to_s[0..200]}`

        *Cheat sheet:*
        • Architecture: `_scripts/tesla/README.md`
        • Home Mac runbook: `_scripts/tesla/launchd/SETUP.md`
        • Prod telemetry runbook: `config/tesla/fleet_telemetry/SETUP.md`
        • Smoke test: `TeslaSetup.run` → 7 → `a`
      MSG
    },
  }.freeze
end
