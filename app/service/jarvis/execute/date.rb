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
    pre.send(direction, amount.to_i)
  end

  def duration
    amount, dur = evalargs
    return unless dur.singularize.to_sym.in?([:second, :minute, :hour, :day, :week, :month, :year])

    amount.to_f.send(dur)
  end
end
