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
    name, notes, data, timestamp = evalargs

    event = user.action_events.create(
      event_name: name,
      notes: notes,
      data: data,
      timestamp: timestamp,
    )
    ::ActionEventBroadcastWorker.perform_async(event.id) if event.persisted?
    event.id
  end

  def update
    id, name, notes, data, timestamp = evalargs

    event = user.action_events.find(id).update({
      event_name: name,
      notes: notes,
      data: data,
      timestamp: timestamp,
    }.compact)
    ::ActionEventBroadcastWorker.perform_async(event.id) if event
    event
  end
end
