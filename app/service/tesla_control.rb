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
    return false if ::TeslaSwitch.disabled?

    ::Rails.env.production? || self.class.force_live_dev
  end

  # Short-circuit when the master switch is off — broadcast loading:false so
  # the UI clears, post the once-per-day "muted" reminder, return falsy.
  def skip_if_muted!(attempted)
    return false if ::TeslaSwitch.enabled?

    TeslaCommand.broadcast(loading: false)
    ::TeslaSwitch.maybe_remind_muted!(attempted)
    true
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

  # Tesla's only trunk command is a toggle, so an explicit open or close reads
  # the car first and leaves it alone when it's already there. Returns
  # :already in that case, so a caller can say so instead of claiming it moved.
  def pop_boot(direction=:toggle)
    direction = parse_to(direction, :open, :close)
    return proxy_command(:actuate_trunk, which_trunk: :rear) if direction == :toggle

    state = vehicle_data.dig(:doors, :trunk)
    raise TeslaError, "couldn't read whether the trunk is open" if state.nil?
    return :already if open?(state) == (direction == :open)

    proxy_command(:actuate_trunk, which_trunk: :rear)
  end

  def windows(direction=:toggle)
    direction = parse_to(direction, :vent, :close)
    return proxy_command(:window_control, command: :vent) if direction == :open

    data = vehicle_data
    window_keys = [:driver_front, :passenger_front, :driver_rear, :passenger_rear]
    is_open = window_keys.any? { |w| data.dig(:windows, w) == true }
    state = direction == :toggle && !is_open ? :vent : :close

    proxy_command(:window_control, command: state, lat: loc[0], lon: loc[1])
  end

  def doors(direction=:toggle)
    direction = parse_to(direction, :unlock, :lock)
    return proxy_command(:door_lock) if direction == :lock
    return proxy_command(:door_unlock) if direction == :unlock

    locked = vehicle_data.dig(:doors, :locked)
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

  def climate(direction=:toggle)
    direction = parse_to(direction, :on, :off)
    direction = vehicle_data.dig(:climate, :hvac_on) ? :off : :on if direction == :toggle
    direction == :on ? start_car : off_car
  end

  def charging(direction=:toggle)
    direction = parse_to(direction, :start, :stop)
    direction = vehicle_data.dig(:charging, :active) ? :stop : :start if direction == :toggle
    proxy_command(direction == :start ? :charge_start : :charge_stop)
  end

  def charge_port(direction)
    direction = parse_to(direction, :open, :close)
    proxy_command(direction == :close ? :charge_port_door_close : :charge_port_door_open)
  end

  def sentry(on)
    proxy_command(:set_sentry_mode, on: on)
  end

  def steering_heat(on)
    proxy_command(:remote_steering_wheel_heater_request, on: on)
  end

  # heater 0 is the driver's seat, 1 the passenger's; level 0 is off, 3 high.
  def seat_heat(seat, level)
    heater = seat.to_s.to_sym == :passenger ? 1 : 0
    proxy_command(:remote_seat_heater_request, heater: heater, level: level.to_i.clamp(0, 3))
  end

  def flash_lights
    proxy_command(:flash_lights)
  end

  def honk
    proxy_command(:honk_horn)
  end

  def navigate(input)
    # navigation_request is REST-only on the Fleet API — sending it through
    # the signed Go-proxy path returns "command requires using the REST API".
    # All other vehicle commands go via proxy_command; this is the exception.
    address_params = {
      type:         :share_ext_content_raw,
      locale:       :"en-US",
      timestamp_ms: (Time.current.to_f * 1000).round,
      value:        { "android.intent.extra.TEXT": self.class.share_text(self.class.resolve_place(input)) },
    }

    command(:navigation_request, address_params)
  end

  # Inserts a single stop into the active trip at `order` (default 1 — first
  # waypoint after the current destination). Uses the place's own coordinates
  # when it has them, and geocodes the street only when it doesn't; no-op if
  # neither gives a point.
  def add_stop(input, order: 1)
    place = self.class.resolve_place(input)
    latlng = place[:loc]
    if latlng.blank?
      address = place[:street].presence || place[:text]
      return false if address.blank?

      latlng = User.me.address_book.geocode(address)
    end
    return false if latlng.blank?

    proxy_command(:navigation_gps_request, lat: latlng[0].to_f, lon: latlng[1].to_f, order: order.to_i)
    true
  rescue StandardError => e
    err("add_stop", e)
    false
  end

  LATLNG_RX = /\A-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\z/

  # Where a destination phrase points, as { name:, street:, loc: } for a place
  # we know, or { text: } for text the car has to search itself.
  #
  # Resolution order:
  #   1. Contact name match (highest priority — e.g. "Sarah" → her address).
  #      AddressBook#match_contact handles possessive/plural normalization
  #      ("Sarah's", "Sarahs", "Sarah's house", "Sarah's place", etc.), then
  #      a contact named inside the phrase ("Herriman DMV", "Horsetail Falls,
  #      Alpine, UT") via AddressBook#address_in_phrase, which picks the
  #      labelled address.
  #   2. Bare "lat,lng" pair (e.g. "40.4804,-111.998")
  #   3. A fuzzy place name resolved to a real place via Places, biased to
  #      where we are now.
  #   4. Anything else passed through as a free-form address string
  def self.resolve_place(input)
    text = input.to_s.strip
    return { text: text } if text.empty?

    address_book = User.me.address_book
    address = address_book.contact_place(text)
    if address.present?
      street = one_line(address.street)
      loc = address.loc.map(&:to_f) if address_book.valid_loc?(address.loc)
      if street.present? || loc.present?
        return { name: address.contact&.name.presence, street: street, loc: loc }.compact
      end
    end

    if text.match?(LATLNG_RX)
      bare = text.gsub(/\s/, "")
      return { text: bare, loc: bare.split(",").map(&:to_f) }
    end

    # Resolve a fuzzy place ("the plunge in Alpine", "Costco") to a concrete
    # place near our current location BEFORE handing it to the car. Without
    # this the raw phrase goes to Tesla's onboard search, which happily grabs
    # the nearest city with a matching word — that's the bug where "the plunge
    # in Alpine" navigated to the town of Alpine instead of the actual spot.
    # Falls through to the raw text when Places can't place it (and off-prod,
    # where nearest_from_name is a no-op).
    place = (address_book.nearest_from_name(text, extract: :place) rescue nil)
    return { name: place[:name], street: one_line(place[:address]), loc: place[:loc] }.compact if place

    { text: text }
  end

  # The address text for a destination: the street when the place has one,
  # otherwise the text as given (or a bare "lat,lng").
  def self.resolve_destination(input)
    place = resolve_place(input)
    place[:street].presence || place[:text] || place[:loc]&.join(",")
  end

  # What the car is sent to search for. A place with coordinates goes the way a
  # phone shares one: its name, its street and a map link pinned to the exact
  # point, so the car lands on the spot rather than on whatever its own search
  # makes of the street. Without coordinates it's the street, or the text.
  def self.share_text(place)
    loc = place[:loc]
    named = place[:name].present? || place[:street].present?
    return place[:street].presence || place[:text].to_s unless loc.present? && named

    link = "https://www.google.com/maps/search/?api=1&query=#{loc.join(",")}"
    [place[:name], place[:street], link].compact_blank.uniq.join("\n")
  end

  def self.one_line(street)
    street.to_s.gsub(/\s*[\r\n]+\s*/, ", ").squish.presence
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
    seat_heat(:driver, 3)
  end

  def heat_passenger
    seat_heat(:passenger, 3)
  end

  def defrost(direction=true)
    direction = parse_to(direction, true, false)
    proxy_command(:set_preconditioning_max, on: direction)
  end

  def cached_vehicle_data
    User.me.caches.get(:car_data)
  end

  def vehicle_data(wake: false)
    return cached_vehicle_data if skip_if_muted!(:vehicle_data)
    return @vehicle_data = cached_vehicle_data unless perform_requests?
    return @vehicle_data if defined?(@vehicle_data)

    @vehicle_data = cached_vehicle_data
    json = get("vehicles/#{vin}/vehicle_data?endpoints=drive_state%3Bvehicle_state%3Blocation_data%3Bcharge_state%3Bclimate_state", wake: wake)
    response = json[:response] if json.is_a?(::Hash)
    return @vehicle_data if response.blank?

    # Callers read the composed car data (`doors`, `climate`, ...), never the
    # raw response, whether the car answered awake or asleep.
    @vehicle_data = ::TeslaCacheStore.record_endpoint(response)
    maintain_tire_pressure_alerts!(@vehicle_data) unless response[:state] == "asleep"
    @vehicle_data
  rescue StandardError => e
    err("Vehicle Data Error", e)
    cached_vehicle_data
  end

  def loc
    [vehicle_data.dig(:location, :lat), vehicle_data.dig(:location, :lng)]
  end

  # Tire pressure: ONLY add a Chores/TODO item when Tesla reports a warning
  # AND the latest pressure reading is actually below threshold. This avoids
  # re-adding items every poll when Tesla's soft-warning value is cached/
  # stale and the real pressure is fine. Both checks must independently
  # agree before we treat it as an alert.
  def maintain_tire_pressure_alerts!(car_data)
    tires = car_data[:tires]
    return unless tires.is_a?(Hash)

    chores = User.me.list_by_name(:Chores)
    todo   = User.me.list_by_name(:TODO)
    [:fl, :fr, :rl, :rr].each do |tire|
      psi = tires[:"#{tire}_psi"]
      next if psi.nil?

      truly_low = psi < ::TeslaTelemetry::TIRE_PRESSURE_LOW
      label = "#{tire_label(tire)} tire pressure low"

      tires[:"#{tire}_soft"] && truly_low ? chores.ensure_item(label) : chores.remove(label)
      tires[:"#{tire}_hard"] && truly_low ? todo.ensure_item(label)   : todo.remove(label)
    end
  end

  def tire_label(tire)
    dir, side = tire.to_s.chars
    "#{dir == "f" ? "Front" : "Back"} #{side == "l" ? "Left" : "Right"}"
  end

  def vin
    @vin ||= DataStorage[:tesla_car_vin]
  end

  def wake_up
    return false if skip_if_muted!(:wake_up)

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

  def wakeup_retry(max_attempts: 5, &block)
    tries = 0
    begin
      tries += 1
      if tries <= max_attempts
        result = block.call
        # Reached the proxies successfully — clear any prior disconnect flag and
        # push it to the dashboard in the same breath. No-ops when it was
        # already clear, so this doesn't churn on every successful command.
        ::TeslaCommand.proxy_unreachable!(false)
        ::TeslaCommand.error!(nil)
        result
      end
    rescue *::TeslaErrorClassifier::PROXY_UNREACHABLE_CLASSES => e
      # Home Mac proxies are down or unreachable. Previously this swallowed
      # silently to avoid noise when laptop was off — now the TeslaSwitch
      # mute covers that case, so being unreachable WITHOUT a deliberate
      # mute is genuinely worth a Slack notification with kickstart steps.
      # Flag it so the dashboard Tesla cell can surface a disconnect indicator.
      # Ahead of err(), which runs a live reachability probe and can take ~10s.
      # The dashboard should show the disconnect immediately, not after it.
      ::TeslaCommand.proxy_unreachable!(true, loading: false)
      err("Home proxy unreachable", e)
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
    return false if skip_if_muted!("GET #{url}")

    TeslaCommand.broadcast(loading: true)

    return dev_output(:GET, url) unless perform_requests?

    wakeup_retry(max_attempts: wake ? 5 : 1) {
      @api.get(url)
    }
  end

  def proxy_command(cmd, params={})
    return false if skip_if_muted!("proxy_command:#{cmd}")

    TeslaCommand.broadcast(loading: true)
    wakeup_retry {
      info(cmd.to_s)
      proxy_post_vehicle("command/#{cmd}", params)
    }
  rescue StandardError => e
    err("proxy_command:#{cmd}", e)
  end

  def command(cmd, params={})
    return false if skip_if_muted!("command:#{cmd}")

    TeslaCommand.broadcast(loading: true)
    wakeup_retry {
      info(cmd.to_s)
      post_vehicle("command/#{cmd}", params)
    }
  rescue StandardError => e
    err("command:#{cmd}", e)
  end

  # Telemetry reports a door as true/false, the endpoint poll as 0 or a
  # non-zero position.
  def open?(state)
    state == true || (state.is_a?(::Numeric) && state.positive?)
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

  def err(title=nil, exception)
    ::TeslaCommand.error!("#{title}: #{exception.message}", loading: false)
    ::SlackNotifier.notify(
      ::TeslaErrorClassifier.slack_message(
        exception,
        where:       title.to_s,
        toggle_link: ::TeslaSwitch.toggle_link(:disable),
      ),
    )
    ::PrettyLogger.error(
      "\b\e[94m[TESLA]\e[31m[ERROR]\n",
      title,
      "[#{exception.class}] #{exception.message}",
      ::PrettyLogger.focused_backtrace(exception.backtrace).first,
    )
  end
end
