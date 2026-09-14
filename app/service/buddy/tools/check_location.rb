# Where the person is, right now.
#
# Rocco, 2026-09-14: "Buddy should be able to access my location and subscribe
# to listening for location changes so that he can act on things like
# arrive/depart." The second half already existed - `remind_when` has taken a
# travel watch, coordinate-matched, since July - and the first half did not, so
# the only way to know where somebody was had been to wait for them to move.
#
# It reads LocationCache, which is what the phone's geofence, the car's
# Bluetooth and TeslaTelemetry all write to, and which TravelResolver and
# ScheduleCondition already read. No new source, no polling, nothing asked of
# the phone: a position is a thing the app is told, not a thing it fetches.
#
# OWNER_ONLY through `feature: :location`, because LocationCache is User.me's
# and there is no per-user one - an ungated version of this would answer
# Chelsea with Rocco's position.
Buddy::Tools.register(
  name:        :check_location,
  description: <<~TXT,
    Where they are right now. Use for "where am I", "am I home yet", "am I
    still at the office", and whenever you need to know before doing something
    else - whether to start the drive timer, whether the thing you're about to
    say makes sense from where they are.

    `place` is OPTIONAL:
      - omit it to read where they are ("where am I?").
      - pass a place to ask about that one specifically ("am I at the gym?") -
        a saved spot, or home.

    This is a POSITION, reported by their phone and their car, and it is only
    as fresh as the last time one of them said something. It comes back with
    how long ago that was. If it is hours old, say so rather than reading it
    out as though it were now - "your phone last put you at home about four
    hours ago" is true, and "you're at home" might not be.

    A phone that has never reported is not an error and not a refusal: say
    plainly that nothing has come in yet.

    To be told when they arrive somewhere or leave, that is `remind_when` with
    a travel condition, not this. This answers about NOW and nothing else.
  TXT
  feature:     :location,
  args:        {
    place: { type: :string, required: false, description: "Place to ask about; omit to read where they are" },
  },
  auto:        true,
  answers:     true,
  # The place is resolved HERE so an unknown one is a sentence in the
  # conversation rather than a raise out of the middle of the answer.
  confirm:     ->(payload, ctx) {
    raise "only the owner's position is tracked" unless ctx.user.me?

    place = payload[:place].to_s.strip
    ScheduleCondition.validate_place!({ place: place }, ctx.user) if place.present?

    { summary: place.present? ? "Are they at #{place}?" : "Where are they?", resolved: { place: place.presence } }
  },
  label:       ->(payload, _ctx) { "Location#{" · #{payload[:place]}" if payload[:place].present?}" },
  execute:     ->(payload, ctx) {
    raise "only the owner's position is tracked" unless ctx.user.me?

    last  = ::LocationCache.last_location
    coord = last&.dig(:loc) || last&.dig("loc")
    raise "nothing has reported a position yet" if coord.blank?

    # `at` is stored in MILLISECONDS - Tesla sends ms since epoch and
    # `LocationCache.set` matched it rather than converting on the way in.
    stamp = (last[:at] || last["at"]).to_i
    seen  = (Time.zone.at(stamp / 1000.0) if stamp.positive?)

    answer = {
      where:       (last[:name] || last["name"]).presence || ::LocationCache.current_location_name(coord),
      at_home:     ::LocationCache.at_home?(coord),
      driving:     ::LocationCache.driving?,
      reported:    (Buddy::Clock.day_at(seen, zone: ctx.user.timezone) if seen),
      # A NUMBER rather than a phrase, because the judgement the description
      # asks for - is this fresh enough to state as a fact - is one the model
      # has to make, and "a while ago" is not something it can make it from.
      minutes_ago: (((Time.current - seen) / 60).round if seen),
    }

    # Asked about one place in particular, answer THAT question rather than
    # handing back a name and leaving the comparison to be guessed at - the
    # place they named and the name the cache happens to carry are routinely
    # different words for the same spot.
    if payload[:place].present?
      answer[:asked_about]   = payload[:place]
      answer[:at_that_place] = ScheduleCondition.near_place?(coord, payload[:place], ctx.user)
    end

    answer.compact
  },
)
