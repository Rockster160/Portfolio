class Jarvis::Execute::ActionEvents < Jarvis::Execute::Executor
  def get
    search, limit, since, order = evalargs
    since ||= Date.new
    limit = limit.presence || 1000

    user.action_events
      .order(timestamp: order.presence || :desc)
      .query(search)
      .limit(limit.to_i.clamp(1, 1000))
      .where(timestamp: since..)
      .serialize
  end

  def add
    name, notes, data, timestamp = evalargs

    event = user.action_events.create(
      name: name,
      notes: notes,
      data: data,
      timestamp: timestamp,
    )
    ::Jarvis.trigger_async(event.user_id, :event, event.serialize.merge(action: :added))
    ::ActionEventBroadcastWorker.perform_async(event.id) if event.persisted?
    event.id
  end

  def update
    id, name, notes, data, timestamp = evalargs

    event = user.action_events.find(id)
    success = event.update({
      name: name,
      notes: notes,
      data: data,
      timestamp: timestamp,
    }.compact)

    return false unless success

    ::Jarvis.trigger_async(event.user_id, :event, event.serialize.merge(action: :changed))
    ::ActionEventBroadcastWorker.perform_async(event.id, false)
    success
  end

  def destroy
    id = evalargs

    event = user.action_events.find(id)
    success = event.destroy

    return false unless success

    ::Jarvis.trigger_async(event.user_id, :event, event.serialize.merge(action: :removed))

    matching_events = ActionEvent
      .where(user_id: event.user_id)
      .ilike(name: event.name)
      .where.not(id: event.id)
    following = matching_events.where("timestamp > ?", event.timestamp).order(:timestamp).first
    UpdateActionStreak.perform_async(following.id) if following.present?

    ::ActionEventBroadcastWorker.perform_async(event.id, false)
    success
  end
end
