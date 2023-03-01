class Jarvis::Execute::ActionEvents < Jarvis::Execute::Executor
  def get
    search, limit, since = evalargs

    user.action_events
      .order(timestamp: :desc)
      .ilike(event_name: search)
      .limit(limit.presence || 1000)
      .where(timestamp: since..)
  end

  def add
    name, notes, timestamp = evalargs

    user.action_events.create(
      event_name: name,
      notes: notes,
      timestamp: timestamp,
    ).persisted?
  end
end
