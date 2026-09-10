# Every travel leg lands here, whichever reporter saw it. One `departed` /
# `arrived` ActionEvent per leg, with each reporter's coordinate filed under
# its own key, so a leg the phone and the car both saw is ONE event carrying
# both — and a leg only the car saw is visibly car-only.
#
# Which reporter answers which question is the whole point:
#
#   :phone — where the PERSON is. Three things report it: the geofence, the
#            car's Bluetooth away from home, and a pairing the car has
#            corroborated by driving off (TeslaTelemetry#carrying_him?). Only
#            this source announces, because every listener on `travel:` (the
#            garage verify, the TODO ping, the queued arrival commands) is
#            about Rocco being gone, not the car being gone.
#   :tesla — where the CAR is. Recorded and queryable, never announced. A
#            `departed` row carrying only this key is the car leaving
#            without him, which is the thing that had no signal at all
#            before: `ActionEvent.search("departed data_source:tesla")`
#            minus the ones that also carry `phone`.
#
# The caller decides what to do with `announce` — see task 54, which is the
# single Jil funnel every source arrives through.
class TravelResolver
  # Long enough for a phone geofence and the car to disagree about when the
  # leg started — the geofence trips at its radius, the car when it rolls —
  # and short enough that two real legs never collapse into one.
  MERGE_WINDOW = 5.minutes

  # The words each reporter uses for the same two things. The geofence
  # automation says `arrived`, the Bluetooth one says `arrive`. None of that
  # should reach the ActionEvent name, which is what every `travel:` listener
  # matches on.
  ACTIONS = {
    depart:   :departed,
    departed: :departed,
    leave:    :departed,
    left:     :departed,
    exit:     :departed,
    arrive:   :arrived,
    arrived:  :arrived,
    enter:    :arrived,
  }.freeze

  ANNOUNCING_SOURCES = %i[phone].freeze

  # How the report reached us, which is a different question from who it is
  # about. The geofence and the Bluetooth radio both speak for the person, and
  # only one of them is right in the garage.
  #
  # Derived and used, never stored: it decides whether to believe a report, it
  # is not a fact about the leg. The event keeps the shape it always had.
  BLUETOOTH = :bluetooth
  GEOFENCE = :geofence

  # The Bluetooth automation's own vocabulary, and the only marker its queued
  # copy carries. The live post says `bluetooth_connected` outright and is
  # labelled in Ruby; the copy the Shortcut replays says nothing but this.
  # Measured over the full 35-day log window: 80 of 81 `depart` lines and 74
  # of 75 `arrive` lines arrived within 20 seconds of a Bluetooth post, while
  # only 10 of 59 `arrived` lines did.
  BLUETOOTH_WORDS = %w[depart arrive].freeze

  class << self
    # Returns the shape task 54 reads: what was recorded, and whether it is
    # this reporter's place to say so. Nil when there is nothing to record at
    # all — an action word we don't know, or a report we're deaf to. Task 54
    # walks through a nil without raising; it runs on every Bluetooth edge in
    # the house, so that path is the common one, not the exception.
    def record(payload, user: ::User.me)
      data = payload.to_h.symbolize_keys
      action = normalize_action(data[:action])
      return nil if action.blank?

      source = (data[:source].presence || :phone).to_sym
      coord = coord_from(data)
      via = normalize_via(data)
      return nil if deaf_to?(via, coord)

      name = place_name(coord) || data[:location].presence

      # Asked BEFORE the merge, and about the leg rather than the row. The
      # test can't be "did this create the row" — the car crosses the home
      # boundary before a geofence at its radius does, so on any drive the car
      # opens the row and the phone arrives second. Announcing on creation
      # would hand the leg to the one source that must never announce, and
      # silence the one that must.
      spoken_for = announced_already?(user, action)
      event = merge_or_create(user, action, source, coord, name)

      {
        event_id: event.id,
        action:   action,
        location: name,
        source:   source,
        lat:      coord&.first,
        lng:      coord&.last,
        created:  event.previously_new_record?,
        announce: ANNOUNCING_SOURCES.include?(source) && !spoken_for,
      }
    end

    def announced_already?(user, action)
      event = recent_event(user, action)
      return false if event.blank?

      event.data.keys.any? { |key| ANNOUNCING_SOURCES.include?(key.to_sym) }
    end

    def normalize_action(raw)
      ACTIONS[raw.to_s.strip.downcase.to_sym]
    end

    # Trusted unless it identifies itself as the radio. A reporter that says
    # nothing is believed, so a `departed` line from a geofence automation is
    # honoured the first time one ever arrives — none has, in the whole log
    # window — without anything being added to it.
    def normalize_via(data)
      explicit = data[:via].to_s.strip.downcase
      return explicit.to_sym if explicit.present?

      BLUETOOTH_WORDS.include?(data[:action].to_s.strip.downcase) ? BLUETOOTH : GEOFENCE
    end

    # Bluetooth reaches into the garage, so a car pulling out of it pairs with
    # a phone that is not going anywhere and never was: on 2026-09-10 the radio
    # connected and dropped five times in three minutes from the same spot,
    # while Rocco was inside the house, and the first of those recorded a
    # departure (action_event 52194) that stood unmatched for the rest of the
    # day.
    #
    # At home the geofence answers this question, and answers it about the
    # PERSON rather than about the car they happen to be standing near.
    # Everywhere else Bluetooth is the only thing that knows, and it is right —
    # a pairing at Home that drops at Horsetail Falls is exactly one journey.
    #
    # It lives here rather than at the two places that report Bluetooth,
    # because both of them reach this one — the live post through
    # LocationCache, and the same automation's queued line replayed through
    # task 185 whenever the phone was out of signal.
    def deaf_to?(via, coord)
      via == BLUETOOTH && ::LocationCache.at_home?(coord)
    end

    # A reporter may hand over a coordinate three ways: separate `lat`/`lng`
    # (the Bluetooth path through LocationCache), a `[lat, lng]` pair, or the
    # `"lat,lng"` string the offline queue tokenizes out of a Shortcut line.
    def coord_from(data)
      pair = (
        if data[:lat].present? && data[:lng].present?
          [data[:lat], data[:lng]]
        else
          Array.wrap(data[:coord].presence || data[:location]).flatten
        end
      )
      pair = pair.first.to_s.split(",") if pair.length == 1
      return nil unless pair.length == 2

      coord = pair.map { |part| Float(part.to_s.strip, exception: false) }
      coord.compact.length == 2 ? coord : nil
    end

    def place_name(coord)
      return nil if coord.blank?

      ::LocationCache.current_location_name(coord)
    end

    # The reporters that saw the same leg write into one row rather than one
    # each. `notes` stays the phone's — it is the name a person reads on the
    # event, and the car's reverse-geocode is the coarser of the two.
    def merge_or_create(user, action, source, coord, name)
      details = { lat: coord&.first, lng: coord&.last, name: name }.compact
      existing = recent_event(user, action)

      if existing
        existing.update!(
          data:  existing.data.merge(source.to_s => details),
          notes: ANNOUNCING_SOURCES.include?(source) ? name : existing.notes,
        )
        existing
      else
        user.action_events.create!(
          name: action, notes: name, data: { source.to_s => details },
        )
      end
    end

    def recent_event(user, action)
      scope = user.action_events.where(name: action)
      scope = scope.where(timestamp: MERGE_WINDOW.ago..)
      scope.order(timestamp: :desc).first
    end
  end
end
