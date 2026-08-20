class LocationCache
  extend DistanceHelper

  # How long a leg has to last before its end is believed. The car's Bluetooth
  # connects, drops and reconnects inside half a minute often enough that it has
  # produced a departure and an arrival at Home, from identical coordinates, on
  # five days in the last six (action_events 51331/51332, 51440/51441,
  # 51501/51502, 51558/51559, 51576/51577 — 8 to 31 seconds apart).
  #
  # Distance alone can't tell those from a real trip, which is worth saying
  # because it looks like it should: EVERY genuine departure leaves from the
  # exact coordinates of the arrival before it (51366 arrived Home at
  # 40.48049,-111.99816 and 51370 departed Home at 40.48049,-111.99816), so a
  # "has it actually moved" gate would refuse every real journey. What separates
  # them is that a real leg ENDS somewhere else, or takes minutes. A pair that
  # is both same-place and seconds apart had no middle.
  FLAP_WINDOW = 90.seconds

  def self.driving?
    !!User.me.caches.dig(:driving, :is_driving)
  end

  def self.driving=(bool)
    return if driving? == bool

    departed = bool
    # At the transition moment `recent_locations[-1]` is the current stopped
    # location — the arrival point for :arrived, the departure point for
    # :departed. Same coord source for both actions.
    here_loc = recent_locations[-1]&.dig(:loc)

    # The flag still flips, because the radio really is off — it's the TRIP
    # that didn't happen. Anything listening on travel is spared a round trip
    # to nowhere, and Task 50 keeps the arrival commands it would have drained.
    if flap?(departed, here_loc)
      remember_transition(departed, here_loc)
      User.me.caches.dig_set(:driving, :is_driving, departed)
      return
    end

    # Built into a local first. `Jil.trigger` carries keyword args of its own,
    # and a hash literal sitting in that last position is one edit away from
    # being read as those keywords instead of as the payload.
    payload = {
      coord: departed ? nil : recent_locations[-1], # If arrived, show current
      from: recent_locations[departed ? -1 : -2], # If arrived, show previous, otherwise current
      location: current_location_name, # Most recent stopped
      lat: here_loc&.first,
      lng: here_loc&.last,
      source: :phone,
      action: departed ? :departed : :arrived,
      (departed ? :departed : :arrived) => current_location_name, # Add this for convenient matchers `travel:arrive:home`
      timestamp: Time.current,
    }

    ::Jil.trigger(User.me, :trytravel, payload)

    remember_transition(departed, here_loc)
    User.me.caches.dig_set(:driving, :is_driving, departed)
  end

  # Does this transition undo the one before it, in the same spot, within the
  # window? Both halves are required — a leg that ends somewhere else is real
  # however short, and one that takes minutes is real however short the hop.
  def self.flap?(departed, here_loc)
    last = User.me.caches.dig(:driving, :last_transition)
    return false if last.blank? || here_loc.blank?

    return false unless last[:departed] == !departed

    at = last[:at].presence&.then { |t| Time.zone.parse(t.to_s) }
    return false if at.nil? || at < FLAP_WINDOW.ago

    there = last[:loc]
    there.present? && near?(there.map(&:to_f), here_loc.map(&:to_f))
  rescue StandardError => e
    # A cache that can't be read is not a reason to swallow a real trip.
    Rails.logger.warn("[LocationCache] flap check: #{e.class}: #{e.message}")
    false
  end

  # Recorded whether or not it fired, so a flap's second half is measured
  # against the flap's first half rather than against the last real journey.
  def self.remember_transition(departed, here_loc)
    User.me.caches.dig_set(:driving, :last_transition, {
      departed: departed,
      loc:      here_loc,
      at:       Time.current.iso8601,
    })
  end

  def self.nearby_contact(loc=nil)
    User.me.address_book.contact_by_loc(loc || last_location[:loc])
  end

  def self.current_location_name(loc=nil)
    nearby_contact(loc)&.name || lookup_location_name(loc)
  end

  def self.lookup_location_name(loc=nil)
    User.me.address_book.reverse_geocode(loc || last_location[:loc], get: :city)
  end

  def self.last_location
    recent_locations.last
  end

  def self.last_coord
    recent_locations.last&.dig(:loc)
  end

  def self.recent_locations
    User.me.caches.dig(:driving, :recent_locations) || []
  end

  def self.set(loc, at=nil)
    at ||= (Time.current.to_f * 1000).round # Tesla sends ms since epoch instead of seconds
    locations = recent_locations
    loc = loc.map(&:to_f)

    return if locations.length >= 3 && near?(locations.last[:loc], loc)

    locations = locations.push({ loc: loc, at: at, name: current_location_name(loc) }).last(3)
    User.me.caches.dig_set(:driving, :recent_locations, locations)
  end
end
