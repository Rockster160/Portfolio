# A "trip" is the sequence of stops a user is driving through on the way
# to an AgendaItem's event location. The leg breakdown lives on the item:
# `metadata.travel.before_legs`, populated by AgendaTravelChain::Service
# when the user adds waypoints to the item's `before:` notes.
#
# TripState tracks "we're on the trip for item X, currently driving to
# leg N." The state is persisted on the user's caches (single jsonb row
# keyed `:trip`), mirroring how LocationCache stores driving state. The
# state is single-trip: a new start replaces any prior in-flight trip.
#
# Lifecycle:
#   * start!(item)     → leg_index=0, fires `:"trip-started"`
#   * advance!         → leg_index+=1, fires `:"trip-advanced"` carrying
#                        the new next-stop string (nil when there's no
#                        further stop — caller can decide whether that
#                        means "trip done" or "navigate to event itself")
#   * finish!          → clear state, fires `:"trip-ended"`
#
# Read helpers:
#   * current_stop      → the leg the user is currently driving TO
#   * next_stop         → one ahead of current — the broadcast target
#                        when current-leg nav completes
#   * arrived_at_current_stop?(reported_loc=nil)
#                       → geofence cross-check: is the user's reported
#                         location within ~500m of the current leg's
#                         destination? Falls back to LocationCache's
#                         most-recent recorded coord when no coord is
#                         passed explicitly.
class TripState
  extend ::DistanceHelper

  KEY = :trip
  # Euclidean threshold in degrees ≈ 500m at mid-latitudes. Loose enough
  # to cover parking lot / curbside arrivals (Tesla's reported coord +
  # the geocoded destination rarely agree to within a city block).
  ARRIVAL_THRESHOLD = 0.005

  class << self
    def current(user=::User.me)
      raw = user&.caches&.dig(KEY)
      raw.is_a?(::Hash) ? raw.symbolize_keys : {}
    end

    def active?(user=::User.me)
      current(user).present?
    end

    def start!(agenda_item, user=::User.me)
      return nil if agenda_item.blank?

      payload = {
        agenda_item_id: agenda_item.id,
        leg_index:      0,
        started_at:     ::Time.current.to_i,
      }
      user.caches.set(KEY, payload)
      fire_trigger(user, :"trip-started", payload.merge(next_stop: current_stop(user)))
      payload
    end

    # Auto-start hook: called when something tells the car to navigate to
    # `destination`. If the user has an upcoming event in the next
    # `lookahead` whose first incoming leg's `to:` matches this
    # destination (case-insensitive trimmed equality), start a trip for
    # it. Returns the started payload, or nil if no trip was started
    # (already active, no match, no waypoints, etc.).
    #
    # Match is intentionally narrow: only the first-leg destination, not
    # mid-trip stops or the event location itself — that's the moment a
    # trip BEGINS. Tesla.navigate to a later stop (after `:trip-started`)
    # is just the natural mid-trip advance and shouldn't restart.
    def start_for_destination!(destination, user=::User.me, lookahead: 4.hours)
      return nil if destination.blank?
      return nil if active?(user)

      target = destination.to_s.strip.downcase
      candidate = user.accessible_agenda_items
        .where(kind: ::AgendaItem.kinds[:event])
        .where(start_at: ::Time.current..(::Time.current + lookahead))
        .where("metadata -> 'travel' ? 'before_legs'")
        .order(:start_at)
        .find { |item|
          first_leg = (item.metadata.dig("travel", "before_legs") || []).first
          first_leg && first_leg["to"].to_s.strip.casecmp(target).zero?
        }
      return nil unless candidate

      start!(candidate, user)
    end

    def advance!(user=::User.me)
      state = current(user)
      return nil if state.blank?

      state[:leg_index] = state[:leg_index].to_i + 1
      user.caches.set(KEY, state)
      next_dest = current_stop(user)
      fire_trigger(user, :"trip-advanced", state.merge(next_stop: next_dest))
      state
    end

    def finish!(user=::User.me)
      state = current(user)
      user.caches.set(KEY, {}) if state.present?
      fire_trigger(user, :"trip-ended", state) if state.present?
      state
    end

    # The leg the user is currently driving TO. Returns the destination
    # address string, or nil if there's no active trip or the index has
    # walked off the end of the leg list.
    def current_stop(user=::User.me)
      leg_destination(user, current(user)[:leg_index].to_i)
    end

    # One leg beyond current — the destination to broadcast after the
    # current leg's nav completes.
    def next_stop(user=::User.me)
      leg_destination(user, current(user)[:leg_index].to_i + 1)
    end

    # Geofence check for any address — is the user's car currently within
    # ARRIVAL_THRESHOLD of `destination`? Used by Tesla.start / Tesla.navigate
    # to skip a redundant car-start when the driver's already there. Same
    # threshold + coord source as `arrived_at_current_stop?`, but takes any
    # destination string rather than being tied to the active trip's leg.
    def car_at?(destination, user: ::User.me)
      return false if destination.blank?

      geocoded = user.address_book.geocode(destination.to_s)
      return false unless geocoded.is_a?(::Array) && geocoded.length == 2 && geocoded.none?(&:blank?)

      coord = car_coord(user)
      return false unless coord.is_a?(::Array) && coord.length == 2 && coord.none?(&:blank?)

      distance(coord.map(&:to_f), geocoded.map(&:to_f)) <= ARRIVAL_THRESHOLD
    end

    # Geofence cross-check. Returns true when the car's reported coord
    # is within ARRIVAL_THRESHOLD of the geocoded current-stop address.
    #
    # `reported_loc` is `[lat, lng]`; when nil, falls back to the Tesla
    # telemetry coord at `user.caches[:car_data][:location]`. That's the
    # canonical car-position source — `LocationCache` is Jarvis-API only
    # and isn't populated by Tesla pushes.
    #
    # `AddressBook#geocode` returns a 2-element `[lat, lng]` array (not a
    # hash) — confirmed at `app/service/address_book.rb:273-275`.
    def arrived_at_current_stop?(user=::User.me, reported_loc: nil)
      expected = current_stop(user)
      return false if expected.blank?

      geocoded = user.address_book.geocode(expected)
      return false unless geocoded.is_a?(::Array) && geocoded.length == 2 && geocoded.none?(&:blank?)

      coord = reported_loc || car_coord(user)
      return false unless coord.is_a?(::Array) && coord.length == 2 && coord.none?(&:blank?)

      distance(coord.map(&:to_f), geocoded.map(&:to_f)) <= ARRIVAL_THRESHOLD
    end

    private

    # Forward to ::Jil.trigger with an explicit kwarg so Ruby 3 binds the
    # data hash to the `data=` positional arg (without explicit kwargs,
    # rspec-mocks' partial-double signature verifier misreads the trailing
    # hash as `**kwargs`).
    def fire_trigger(user, scope, data)
      ::Jil.trigger(user, scope, data, auth: :trigger)
    end

    def leg_destination(user, index)
      return nil if index.negative?

      state = current(user)
      return nil if state.blank?

      item = ::AgendaItem.find_by(id: state[:agenda_item_id])
      return nil if item.blank?

      legs = item.metadata.dig("travel", "before_legs") || []
      legs[index] && legs[index]["to"].to_s.presence
    end

    # Tesla-derived car position. car_data is composed by
    # TeslaCacheStore#compose_location and stored as `{lat:, lng:, ...}`
    # — verified against the live prod cache. Returns nil if no location
    # has been recorded yet (e.g. brand-new user, telemetry not flowing).
    def car_coord(user)
      loc = user.caches.dig(:car_data, :location)
      return nil unless loc.is_a?(::Hash)

      lat = loc[:lat] || loc["lat"]
      lng = loc[:lng] || loc["lng"]
      return nil if lat.blank? || lng.blank?

      [lat, lng]
    end
  end
end
