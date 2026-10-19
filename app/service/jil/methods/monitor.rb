class Jil::Methods::Monitor < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Monitor]
  #   #loading(String:UUID)
  #   #broadcast(String:UUID content(MonitorData))
  # *[MonitorData]
  #   #content(Text)
  #   #timestamp(Date|Boolean)
  #   #blip(Numeric?)
  #   #data(Hash)

  def loading(name, bool)
    broadcast_to_all_users(id: name, channel: name, loading: bool)
    { id: name, channel: name }
  end

  def broadcast(name, param_blocks, loading)
    data = param_blocks.inject({}) { |acc, hash| acc.merge(hash) }.deep_symbolize_keys
    data[:id] = name
    data[:channel] = name
    data[:timestamp] = (
      case data[:timestamp]
      when TrueClass then ::Time.current.to_i
      when FalseClass then false
      else data[:timestamp].to_i.then { |n| n.zero? ? ::Time.current.to_i : n }
      end
    )
    data[:loading] = loading

    broadcast_to_all_users(data)
    { id: name, channel: name }
  end

  def refresh(name, data)
    ::Jil.trigger(
      @jil.user, :monitor,
      { id: name, channel: name, refresh: true }.reverse_merge(data.presence || {}),
      auth: :trigger, auth_id: @jil.task&.id
    )
    { id: name, channel: name }
  end

  # [MonitorData]

  def content(text)
    { result: text }
  end

  def timestamp(val) # time | bool
    { timestamp: val }
  end

  def timestampFormat(val)
    { timestamp_format: val }
  end

  def blip(count)
    { blip: count&.zero? ? nil : count.to_s.first(3).presence }
  end

  def data(data={})
    { data: data }
  end

  private

  def broadcast_to_all_users(data)
    task = @jil.broadcast_task
    users = task.present? ? task.broadcast_users.to_a : [@jil.user]
    # Who the broadcast BELONGS to — the task's owner, or the running user behind
    # a bare broadcast. A board decides a Whisper feed belongs on it by matching
    # this against its OWN owner, not its viewer: a shared board keeps showing the
    # owner's feeds to whoever opens it, while a different person's board that
    # merely watches a "Whisper" group never picks them up. See buddy/board_scope.js.
    owner_id = task&.user_id || @jil.user&.id
    stamped = data.merge(owner_id: owner_id)
    users.each { |user| ::MonitorChannel.broadcast_to(user, stamped) }
    # A group a feed is aimed at becomes one a board can be pointed at.
    owner = task&.user || @jil.user
    ::Buddy::BoardFeedGroups.remember!(owner, data[:data][:groups]) if data[:data].is_a?(Hash)
    # The Whisper feed is also what a board's pet holds its face on, and that has
    # to be known server-side too: a board opening fresh and the board index
    # both paint it before any socket has spoken.
    return unless data[:channel].to_s == ::Buddy::BoardFace::WHISPER_CHANNEL.to_s

    ::Buddy::BoardFace.record_whisper!(owner, data[:data])
  end
end
