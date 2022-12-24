class Jarvis::Execute::ActionEvents < Jarvis::Execute::Executor
  def get
    search, limit, since = evalargs

    user.action_events
      .order(timestamp: :desc)
      .name_search(search)
      .limit(limit.presence || 1000)
      .where(timestamp: since..)
  end
end
