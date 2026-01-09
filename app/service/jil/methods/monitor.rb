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
    ::MonitorChannel.broadcast_to(@jil.user, id: name, channel: name, loading: bool)
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

    ::MonitorChannel.broadcast_to(@jil.user, data)
    { id: name, channel: name }
  end

  def refresh(name, data)
    ::Jil.trigger(
      @jil.user, :monitor,
      { id: name, channel: name, refresh: true }.reverse_merge(data.presence || {})
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
end
