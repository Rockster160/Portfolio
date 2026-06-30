class Jil::Methods::Trip < Jil::Methods::Base
  # Jil-facing wrapper around `TripState` — drives multi-stop trip
  # advancement from a Jil task listening on Tesla telemetry triggers.
  #
  # Typical pattern (a user task listening on `tesla_trip_ended`):
  #
  #   *evt = Global.input_data()::Hash
  #   arrived = Trip.arrived?()::Boolean
  #   branch = Global.if({
  #     ifArrived = Global.ref(arrived)::Boolean
  #   }, {
  #     advanced = Trip.advance()::Boolean
  #     nextStop = Trip.current_stop()::String
  #     hasNext = String.length(nextStop)::Numeric
  #     gotNext = Boolean.compare(hasNext, ">", 0)::Boolean
  #     navBranch = Global.if({
  #       ifNext = Global.ref(gotNext)::Boolean
  #     }, {
  #       navigated = Tesla.navigate(nextStop)::Boolean
  #     }, {
  #       ended = Trip.finish()::Boolean
  #     })::Any
  #   }, {
  #     noop = Boolean.new(false)::Boolean
  #   })::Any
  #
  # Schema entries live in `app/service/jil/schema.txt` under [Trip].

  def cast(value)
    @jil.cast(value, :Boolean)
  end

  # Start a trip targeting an AgendaItem. Accepts an AgendaItem hash, an
  # AgendaItem record, or a numeric/string id. Returns false when the id
  # doesn't resolve or no caller user is set.
  def start(item_value)
    return false unless @jil.user

    item = resolve_agenda_item(item_value)
    return false if item.blank?

    !!::TripState.start!(item, @jil.user)
  end

  def advance
    return false unless @jil.user

    !!::TripState.advance!(@jil.user)
  end

  def finish
    return false unless @jil.user

    !!::TripState.finish!(@jil.user)
  end

  def active?    = !!@jil.user && ::TripState.active?(@jil.user)
  def current_stop = ::TripState.current_stop(@jil.user).to_s
  def next_stop    = ::TripState.next_stop(@jil.user).to_s

  # Geofence cross-check — listens-on tasks pair this with
  # `tesla_trip_ended` to confirm the car's reported destination matches
  # the trip's current expected stop before advancing.
  def arrived?
    return false unless @jil.user

    ::TripState.arrived_at_current_stop?(@jil.user)
  end

  private

  def resolve_agenda_item(value)
    case value
    when ::AgendaItem then value
    when ::Hash       then ::AgendaItem.locate_for_user(value[:id] || value["id"], @jil.user)
    when ::Numeric, ::String then ::AgendaItem.locate_for_user(value, @jil.user)
    end
  end
end
