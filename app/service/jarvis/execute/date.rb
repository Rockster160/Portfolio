class Jarvis::Execute::Date < Jarvis::Execute::Executor
  def now
    Time.current.in_time_zone(user.timezone)
  end

  def round
    pre, direction, dur = evalargs
    return unless direction.to_sym.in?([:beginning, :end])
    return unless dur.singularize.to_sym.in?([:second, :minute, :hour, :day, :week, :month, :year])

    pre.send("#{direction}_of_#{dur}")
  end

  def adjust
    pre, direction, amount = evalargs
    pre.send(direction, amount.to_i.seconds)
  end

  def duration
    amount, dur = evalargs
    return unless dur.singularize.to_sym.in?([:second, :minute, :hour, :day, :week, :month, :year])

    amount.to_f.send(dur)
  end

  def format
  end

  def piece
    time, piece = evalargs
    piece = piece.singularize.to_sym
    return unless piece.in?([:second, :minute, :hour, :day, :week, :month, :year])

    piece = :sec if piece == :second
    piece = :min if piece == :minute
    return time.to_date.cweek if piece == :week

    time.send(piece)
  end
end
