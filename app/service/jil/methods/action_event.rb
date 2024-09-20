class Jil::Methods::ActionEvent < Jil::Methods::Base
  def cast(value)
    case value
    when ::ActionEvent then value.serialize
    else @jil.cast(value, :Hash)
    end
  end

  def find(id)
    events.find_by(id: id)
  end

  def search(q, limit, date, order)
    limit = (limit.presence || 50).to_i.clamp(1..100)
    scoped = events.query(q).per(limit)
    scoped = scoped.where(timestamp: @jil.cast(date, :Date)..) if date.present?
    scoped = scoped.order(created_at: order) if [:asc, :desc].include?(order.to_s.downcase.to_sym)
    scoped.serialize
  end

  def add(name, notes, data, date)
    events.create(
      name: name,
      notes: notes.presence,
      data: @jil.cast(data.presence || {}, :Hash),
      timestamp: date.present? ? @jil.cast(date, :Date) : ::Time.current,
    )
  end

  def id(event)
    event[:id]
  end

  def name(event)
    event[:name]
  end

  def notes(event)
    event[:notes]
  end

  def data(event)
    event[:data]
  end

  def date(event)
    event[:date]
  end

  def update(event, name, notes, data, date)
    load_event(event).update({
      name: name,
      notes: notes,
      data: data,
      date: date,
    }.compact_blank)
  end

  def destroy(event)
    event.destroy
  end

  private

  def load_event(jil_event)
    @jil.user.action_events.find(cast(jil_event)[:id])
  end

  def events
    @events ||= @jil.user.action_events.order(timestamp: :desc).page(1).per(50)
  end
end
