class TeslaError < StandardError; end
class TeslaNotAuthorized < StandardError; end

class TeslaControl
  attr_accessor :api

  # Opt-in flag for local Tesla testing. When true, dev consoles will
  # actually send signed commands through the local Ruby relay + Go proxy
  # instead of short-circuiting via dev_output. Set/cleared by the
  # TeslaSetup wizard around individual test commands; never persisted.
  # Prod always performs requests regardless.
  cattr_accessor :force_live_dev, default: false

  def self.me
    new(User.me)
  end

  # Single source of truth: the Tesla integration is bound to User.me only.
  # Every command path (channels, Jarvis, Jil methods, workers) ends up
  # constructing a TeslaControl, so guarding here blocks all of them at once.
  def self.guard!(user)
    raise TeslaNotAuthorized, "Tesla integration is restricted to User.me" unless user&.me?

    user
  end

  def perform_requests?
    ::Rails.env.production? || self.class.force_live_dev
  end

  def initialize(user)
    self.class.guard!(user)
    @api = ::Oauth::TeslaApi.new(user)
  end

  delegate :code=, to: :@api

  def authorize
    @api.auth_url
  end

  def refresh
    @api.proxy_refresh
  rescue StandardError => e
    err("Refresh Error", e)
    raise
  end

  def pop_boot(direction=:toggle)
    direction = parse_to(direction, :open, :close)
    return proxy_command(:actuate_trunk, which_trunk: :rear) if direction == :toggle

    state = vehicle_data.dig(:vehicle_state, :rt).to_i.positive? ? :open : :close
    return if state == direction

    proxy_command(:actuate_trunk, which_trunk: :rear)
  end

  def windows(direction=:toggle)
    direction = parse_to(direction, :vent, :close)
    return proxy_command(:window_control, command: :vent) if direction == :open

    data = vehicle_data
    windows = [:fd, :fp, :rd, :rp]
    is_open = windows.any? { |window| data.dig(:vehicle_state, :"#{window}_window").to_i.positive? }
    state = direction == :toggle && !is_open ? :vent : :close

    proxy_command(:window_control, command: state, lat: loc[0], lon: loc[1])
  end

  def doors(direction=:toggle)
    direction = parse_to(direction, :unlock, :lock)
    return proxy_command(:door_lock) if direction == :lock
    return proxy_command(:door_unlock) if direction == :unlock

    locked = vehicle_data.dig(:vehicle_state, :locked)
    locked ? proxy_command(:door_unlock) : proxy_command(:door_lock)
  end

  def pop_frunk
    proxy_command(:actuate_trunk, which_trunk: :front)
  end

  def start_car
    proxy_command(:auto_conditioning_start)
  end

  def off_car
    proxy_command(:auto_conditioning_stop)
  end

  def honk
    proxy_command(:honk_horn)
  end

  def navigate(input)
    # navigation_request is REST-only on the Fleet API — sending it through
    # the signed Go-proxy path returns "command requires using the REST API".
    # All other vehicle commands go via proxy_command; this is the exception.
    address = self.class.resolve_destination(input)
    address_params = {
      type:         :share_ext_content_raw,
      locale:       :"en-US",
      timestamp_ms: (Time.current.to_f * 1000).round,
      value:        { "android.intent.extra.TEXT": address },
    }

    command(:navigation_request, address_params)
  end

  # Resolution order:
  #   1. Contact name match (highest priority — e.g. "Sarah" → her address).
  #      AddressBook#match_contact handles possessive/plural normalization
  #      ("Sarah's", "Sarahs", "Sarah's house", "Sarah's place", etc.).
  #   2. Bare "lat,lng" pair (e.g. "40.4804,-111.998")
  #   3. Anything else passed through as a free-form address string
  # Tesla's share endpoint accepts both addresses and lat,lng — we just
  # hand the text along once we've picked the right form.
  def self.resolve_destination(input)
    text = input.to_s.strip
    return text if text.empty?

    contact_address = User.me.address_book.match_contact(text)&.primary_address&.street
    return contact_address if contact_address.present?

    return text.gsub(/\s/, "") if text.match?(/\A-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\z/)

    text
  end

  def set_temp(temp_F, skip_verify: false)
    temp_F = temp_F.to_f.clamp(59..82)
    # Tesla expects temp in Celsius
    temp_C = ((temp_F - 32) * (5 / 9.to_f)).round(1)
    proxy_command(:set_temps, driver_temp: temp_C, passenger_temp: temp_C)
    # For some reason sometimes when setting temp while car is sleeping, it instead sets to TEMP_MIN
    # To counter that, wait 5 seconds after proxy_command is performed and attempt to set the temp again.
    # `skip_verify` is set by TeslaVerifyTempWorker so its own retries don't
    # spawn fresh verify chains and defeat the attempt counter.
    TeslaVerifyTempWorker.perform_in(5.seconds, temp_F) if Rails.env.production? && !skip_verify
  end

  def heat_driver
    proxy_command(:remote_seat_heater_request, heater: 0, level: 3)
  end

  def heat_passenger
    proxy_command(:remote_seat_heater_request, heater: 1, level: 3)
  end

  def defrost(direction=true)
    direction = parse_to(direction, true, false)
    proxy_command(:set_preconditioning_max, on: direction)
  end

  def cached_vehicle_data
    User.me.caches.get(:car_data)
  end

  def vehicle_data(wake: false)
    return @vehicle_data = cached_vehicle_data unless perform_requests?
    return @vehicle_data if defined?(@vehicle_data)

    @vehicle_data ||= cached_vehicle_data
    get("vehicles/#{vin}/vehicle_data?endpoints=drive_state%3Bvehicle_state%3Blocation_data%3Bcharge_state%3Bclimate_state", wake: wake)&.tap { |json|
      car_data = json.is_a?(::Hash) && json[:response]
      cached_data = cached_vehicle_data
      break cached_data if car_data.blank?

      car_data[:timestamp] = car_data.dig(:vehicle_state, :timestamp) # Bubble up to higher key

      User.me.caches.set(:car_data, car_data)
      break car_data if car_data[:state] == "asleep"

      # Tire pressure: ONLY add a Chores/TODO item when Tesla reports a
      # warning AND the latest pressure reading is actually below threshold.
      # This avoids re-adding items every poll when Tesla's soft-warning
      # value is cached/stale and the real pressure is fine. Both checks
      # must independently agree before we treat it as an alert.
      if car_data[:vehicle_state]&.key?(:tpms_soft_warning_fl)
        chores = User.me.list_by_name(:Chores)
        todo   = User.me.list_by_name(:TODO)
        [:fl, :fr, :rl, :rr].each do |tire|
          tirename = tire.to_s.chars.then { |dir, side|
            [dir == "f" ? "Front" : "Back", side == "l" ? "Left" : "Right"]
          }.join(" ")
          label = "#{tirename} tire pressure low"
          psi   = car_data.dig(:vehicle_state, :"tpms_pressure_#{tire}").to_f
          truly_low = psi.positive? && psi < ::TeslaTelemetry::TIRE_PRESSURE_LOW

          soft = car_data.dig(:vehicle_state, :"tpms_soft_warning_#{tire}") == true
          if soft && truly_low
            chores.add(label)
          else
            chores.remove(label)
          end

          hard = car_data.dig(:vehicle_state, :"tpms_hard_warning_#{tire}") == true
          if hard && truly_low
            todo.add(label)
          else
            todo.remove(label)
          end
        end
      end
    } || cached_vehicle_data
  rescue StandardError => e
    err("Vehicle Data Error", e)
    cached_vehicle_data
  end

  def loc
    [vehicle_data.dig(:drive_state, :latitude), vehicle_data.dig(:drive_state, :longitude)]
  end

  def vin
    @vin ||= DataStorage[:tesla_car_vin]
  end

  def wake_up
    res = proxy_post_vehicle(:wake_up)
    res&.dig(:response, :state) == "online"
  end

  private

  def tesla_exc_code(exc)
    # Some failure modes (connection reset, timeout, DNS) raise the
    # response-bearing exception class but with `response == nil`. The
    # wakeup_retry caller treats anything non-401/403 as "give up", so
    # collapsing to 500 lands in the right branch without leaking a
    # NoMethodError into the worker's exception report.
    return 500 if exc.response.nil?
    # Tesla Proxy Server is correctly receiving the errors codes, but returning 500 for them.
    return exc.response.code unless exc.response.code == 500

    json = JSON.parse(exc.response.body, symbolize_names: true)
    case json[:error]
    when "vehicle unavailable: vehicle is offline or asleep" then 408
    else 500.tap { info("Unknown Status", (json[:error]).to_s) }
    end
  rescue JSON::ParserError
    500
  end

  # Exceptions raised when the home-Mac proxies (Go + Ruby relay) can't
  # be reached at all — laptop off, off the home wifi, proxy daemon not
  # yet up, etc. Distinct from Tesla-API errors with an HTTP response.
  # We treat these as "command skipped" rather than escalating to Slack.
  PROXY_UNREACHABLE_ERRORS = [
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    SocketError,
    RestClient::ServerBrokeConnection,
    RestClient::Exceptions::OpenTimeout,
    RestClient::Exceptions::ReadTimeout,
  ].freeze

  def wakeup_retry(max_attempts: 5, &block)
    tries = 0
    begin
      tries += 1
      block.call if tries <= max_attempts
    rescue *PROXY_UNREACHABLE_ERRORS => e
      # Home proxy is down (most often: laptop is off / away from home
      # wifi). Don't err() — that posts to Slack with a full stack trace
      # and turns a known-expected scenario into noise. info() routes to
      # PrettyLogger only.
      info("Home proxy unreachable", "#{e.class.name}: #{e.message.to_s[0..120]} — Tesla command skipped.")
      TeslaCommand.broadcast(loading: false)
      false
    rescue RestClient::ExceptionWithResponse => e
      case tesla_exc_code(e)
      when 401, 403
        if tries > 1 # Should only need to refresh on the first attempt
          info("Failed to reauthorize")
          raise
        end
        info("Token expired. Refreshing...")
        TeslaCommand.broadcast(loading: true)
        refresh
        tries -= 1 # Refresh doesn't count as an attempt
        info("Token refreshed. Trying again!")
        retry
      when 408
        User.me.caches.dig_set(:car_data, :state, :asleep)
        @vehicle_data = User.me.caches.get(:car_data) # reset cache
        if tries >= max_attempts
          TeslaCommand.broadcast(loading: false)
          return false # Did not wake up
        end
        info("Attempting to wake up... (#{tries}/#{max_attempts})")
        TeslaCommand.broadcast(loading: true)
        !wake_up && sleep(10) # Only sleep if still sleeping
        info("Trying again after wakeup!")
        retry
      else
        # Don't notify here — the outer caller (proxy_command / command / get)
        # has its own rescue+err and would double-post to Slack. Just propagate.
        raise
      end
    rescue StandardError => e
      err("Wakeup Error", e)
    end
  end

  def get(url, wake: false)
    TeslaCommand.broadcast(loading: true)

    return dev_output(:GET, url) unless perform_requests?

    wakeup_retry(max_attempts: wake ? 5 : 1) {
      @api.get(url)
    }
  end

  def proxy_command(cmd, params={})
    TeslaCommand.broadcast(loading: true)
    wakeup_retry {
      info(cmd.to_s)
      proxy_post_vehicle("command/#{cmd}", params)
    }
  rescue StandardError => e
    err("Proxy Command Error", e)
  end

  def command(cmd, params={})
    TeslaCommand.broadcast(loading: true)
    wakeup_retry {
      info(cmd.to_s)
      post_vehicle("command/#{cmd}", params)
    }
  rescue StandardError => e
    err("Command Error", e)
  end

  def parse_to(val, truthy, falsy)
    val = val.to_s.to_sym
    return :toggle if val == :toggle
    return truthy if val == :open
    return falsy if val == :close

    val
  end

  def proxy_post_vehicle(endpoint, params={})
    return dev_output(:PROXY_POST, "vehicles/#{vin}/#{endpoint}", params) unless perform_requests?
    raise "Should not POST in tests!" if Rails.env.test?

    @api.proxy_post("vehicles/#{vin}/#{endpoint}", params).tap { |res|
      info("Response", res.to_s)
    }
  end

  def post_vehicle(endpoint, params={})
    return dev_output(:POST, "vehicles/#{vin}/#{endpoint}", params) unless perform_requests?
    raise "Should not POST in tests!" if Rails.env.test?

    @api.post("vehicles/#{vin}/#{endpoint}", params).tap { |res|
      info("Response", res.to_s)
    }
  end

  def dev_output(method, url, params={})
    ::PrettyLogger.info(
      "\b\e[94m[TESLA]\e[0m",
      "   #{method}   ".center(50, "="),
      url,
      Api.pretty_obj(params),
    )
    {}
  end

  def info(title, detail=nil)
    if detail
      detail = "\n" + PrettyLogger.pretty_message(detail)
      detail = detail.gsub(/:(\w+)=>/, '\1: ')
    end
    ::PrettyLogger.info("\b\e[94m[TESLA]\n#{title}#{detail}\e[0m")
  end

  # Multi-line context that gets prepended to every Tesla error post in Slack.
  # The point is that future-you sees the error months from now after Tesla
  # changes something and doesn't have to remember how any of this works —
  # the message itself points at the wizard, the runbooks, and the re-auth
  # one-liner.
  SLACK_ERROR_HINTS = <<~MSG.freeze
    *Tesla error.* If this is unfamiliar, start here:
    • Smoke-test commands locally: `TeslaSetup.run` → option 7 → `a` (flash_lights)
    • Re-auth (if 401 / refresh failed): `Oauth::TeslaApi.me.auth_url` from prod console, open in browser, approve
    • Re-register telemetry: `Oauth::TeslaApi.me.request_telemetry`
    • Architecture + cheat sheet: `_scripts/tesla/README.md`
    • Prod telemetry runbook (systemd, certs, logs): `config/tesla/fleet_telemetry/SETUP.md`
    • Home Mac proxies (Go + Ruby relay): `_scripts/tesla/launchd/SETUP.md`
  MSG

  def err(title=nil, exception)
    ::SlackNotifier.err(exception, "#{SLACK_ERROR_HINTS}\n*Where:* #{title}\n")
    ::PrettyLogger.error(
      "\b\e[94m[TESLA]\e[31m[ERROR]\n",
      title,
      "[#{exception.class}] #{exception.message}",
      ::PrettyLogger.focused_backtrace(exception.backtrace).first,
    )
  end
end
