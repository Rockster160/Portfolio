class Jarvis::Execute::ActionEvents < Jarvis::Execute::Executor
  def get
    search, limit, since = evalargs

    user.action_events
      .order(timestamp: :desc)
      .search(search)
      .limit(limit.presence || "")
      .where(timestamp: since..)
  end
end
