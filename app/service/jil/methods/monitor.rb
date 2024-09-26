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
  #   #extra(Hash)

  def loading(name, bool)
    ::MonitorChannel.broadcast_to(@jil.user, id: name, loading: bool)
    { id: name }
  end

  def broadcast(name, param_blocks, loading)
    data = param_blocks.inject({}) { |acc, hash| acc.merge(hash) }
    data[:timestamp] = data[:timestamp].presence || ::Time.current.to_i
    data[:id] = name
    data.delete(:loading) # -- For some reason results in `undefined`

    ::MonitorChannel.broadcast_to(@jil.user, data)
    { id: name }
  end

  def refresh(name, data)
    ::Jil.trigger(@jil.user.id, :monitor, { refresh: true }.merge(data.presence || {}))
    { id: name }
  end

  # [MonitorData]

  def content(text)
    { result: text }
  end

  def timestamp(val) # time | bool
    { timestamp: val }
  end

  def blip(count)
    { blip: count&.zero? ? nil : count.to_s.first(3).presence }
  end

  def extra(data={})
    { extra: data }
  end
end
