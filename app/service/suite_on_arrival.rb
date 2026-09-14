# The suite number, said when they get there rather than five minutes before it
# starts.
#
# FeatureRequest 5, 4 Sep: "Send suite number on arrival if earlier than the 5
# minute mark." Rocco, 2026-09-14: "Previously, 5 minutes prior to the start of
# an event that had a suite number in the address, Jarvis would send a ping with
# the suite number. However, sometimes I'd be arriving early because of traffic
# or paperwork or whatever else, so the thought was to change that feature to
# send the suite number upon arrival to the location - either car or phone
# reporting."
#
# Prod tasks 347 / 348 are the old pair: 347 pulls a suite out of an agenda
# item's location on save and schedules a `suite-reminder` trigger for -5
# minutes; 348 pings it. That schedule STAYS, as the backstop for an arrival
# nobody reported - walked there, got a lift, phone dead. This is what fires it
# early, and cancelling the scheduled copy is what stops it being said twice.
#
# Why Ruby and not the Jil task: Jil has no geometry. There is no distance, no
# geocode and no coordinate type in the schema, so "is this arrival AT that
# appointment" cannot be asked there. It can be asked here, where AddressBook
# and DistanceHelper already live, and the answer goes back to Jil as two
# strings through `Custom.suite_on_arrival`.
class SuiteOnArrival
  include DistanceHelper

  # Matches task 347's own regex, because the two have to agree about what a
  # suite IS - one of them deciding an item qualifies while the other doesn't
  # means either a ping with nothing in it or no ping at all.
  SUITE_RX = /
    (
      \#[A-Za-z0-9-]+
      |
      \b(?:suite|ste|room|rm|unit|apt|apartment|floor|fl|bldg|building)\s*[A-Za-z0-9-]+\b
    )
  /xi

  # How far ahead an appointment counts as the one they just walked into.
  #
  # Generous on purpose - arriving early IS the request, and somebody who leaves
  # two hours of slack for a clinic across the valley is the person this is for.
  # What keeps it honest is the coordinate check, not the clock: the window only
  # decides which items are worth asking about.
  AHEAD = 3.hours

  # And a little behind, because the arrival that matters most is the one that
  # lands just after the hour on a day the traffic won.
  BEHIND = 30.minutes

  # Nothing past this is asked about. Each candidate can cost a geocode the
  # first time its location is seen, and an unbounded list is an unbounded bill
  # on a path that runs every time he parks.
  MAX_CANDIDATES = 8

  class << self
    # `{ "name" => ..., "suite" => ... }` for the appointment they have just
    # arrived at, or `{}`. String keys because the caller is Jil, which reads a
    # Hash with `.get("name")`.
    def call(payload, user: ::User.me)
      new(payload, user).call
    end
  end

  def initialize(payload, user)
    @payload = (payload || {}).to_h.symbolize_keys
    @user    = user
  end

  def call
    return {} unless arrived?

    coord = arrival_coord
    return {} if coord.blank?

    item = candidates.find { |candidate| at?(coord, candidate.location) }
    return {} if item.nil?

    # Said once. The -5 minute copy exists for the arrival that never gets
    # reported, and once this has fired it is a repeat rather than a backstop.
    cancel_scheduled(item)

    {
      "name"     => item.name.to_s,
      "suite"    => suite_in(item.location).to_s,
      # Carried so the task can address the message, not because it decides who
      # hears it - see the note in the deploy script about why an ARRIVAL is
      # said to the person who arrived rather than to everyone on the calendar.
      "event_id" => item.id,
    }
  end

  private

  # TravelResolver normalises every reporter's vocabulary to `arrived` /
  # `departed` before this sees it, so there is one word to check.
  def arrived?
    @payload[:action].to_s.casecmp("arrived").zero?
  end

  def arrival_coord
    lat = @payload[:lat]
    lng = @payload[:lng]
    return [lat.to_f, lng.to_f] if lat.present? && lng.present?

    # A queued report replayed out of a dead zone can arrive without a pair of
    # numbers on it. The phone's last known position is the honest fallback -
    # it is what the report was about.
    ::LocationCache.last_coord
  end

  # Today's appointments around now that name a suite at all. Ordered by start
  # so the nearest one wins a tie, and read in ONE query.
  def candidates
    window = (Time.current - BEHIND)..(Time.current + AHEAD)
    scope  = AgendaItem.where(agenda_id: Agenda.where(user_id: @user.id).select(:id))
    scope  = scope.where(start_at: window).where(cancelled_at: nil, completed_at: nil)
    scope.order(:start_at).limit(MAX_CANDIDATES).select { |item| suite_in(item.location).present? }
  end

  def suite_in(location)
    location.to_s[SUITE_RX, 1]
  end

  # The coordinate check that Jil could not do. `near?` defaults to ~110m,
  # which is the same radius LocationCache treats as "at the house" and
  # BuddyWatch as "at the place" - one boundary, everywhere.
  def at?(coord, location)
    there = @user.address_book.coords_for_location(location)
    return false if there.blank?

    near?(coord.map(&:to_f), there.map(&:to_f))
  rescue StandardError => e
    # A location that won't geocode is one candidate lost, never the arrival.
    Rails.logger.warn("[SuiteOnArrival] #{location.inspect}: #{e.class}: #{e.message}")
    false
  end

  # Task 347 schedules these through `Global.trigger_for(evt, "suite-reminder",
  # ...)`, which writes a ScheduledTrigger keyed on (source_item, name) - the
  # same pair `Global#remove_trigger_for` tears one down by. Done here rather
  # than through that method because it needs a live `@jil`, and this is not
  # running inside a task.
  def cancel_scheduled(item)
    rec = @user.scheduled_triggers.find_by(source_item_id: item.id, name: "suite-reminder")
    return if rec.nil?

    ::Jil::Schedule.cancel(rec)
    rec.destroy
  rescue StandardError => e
    # Worst case is the -5 minute copy arriving as well, which is a repeat of
    # something true. Never a reason to swallow the arrival ping.
    Rails.logger.warn("[SuiteOnArrival] couldn't cancel ##{item.id}: #{e.class}: #{e.message}")
  end
end
