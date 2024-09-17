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
    events.query(q).serialize
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
