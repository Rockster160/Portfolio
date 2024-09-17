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

  private

  def events
    @events ||= @jil.user.action_events.order(timestamp: :desc).page(1).per(50)
  end
end
