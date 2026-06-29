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
    body = MESSAGES.fetch(category).call(exception, where)
    [
      header(category, where),
      body,
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

  MESSAGES = {
    proxy_unreachable:   ->(exc, _where) {
      <<~MSG.strip
        Couldn't reach the home Mac proxies at `#{DataStorage[:local_ip]}:3142`.
        `#{exc.class}: #{exc.message.to_s[0..160]}`

        *Likely causes (in order):*
        1. Home Mac is asleep / off network → wake it
        2. launchd jobs crashed → on the Mac:
           `launchctl kickstart -k gui/$UID/com.ardesian.tesla-go-proxy`
           `launchctl kickstart -k gui/$UID/com.ardesian.tesla-ruby-relay`
        3. Public IP changed and duckdns lagged → check `DataStorage[:local_ip]` vs `curl ifconfig.me` on the Mac
        4. Router port-forward on 3142 broke
      MSG
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
