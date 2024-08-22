class Jil::Methods::Date < Jil::Methods::Base
  TIMEPIECES = %w(second minute hour day week month year)

  def cast(value)
    case value
    when Numeric then value < 10**10 ? Time.at(value) : Time.at(value/1000.to_f)
    when String then DateTime.parse(value)
    else value.to_datetime
    end
  rescue Date::Error, TypeError, NoMethodError
    DateTime.new
  end

  def execute(line)
    case line.methodname
    when :new then DateTime.new(*evalargs(line.args))
    else
      fallback(line)
    end
  end

  def now
    Time.current
  end

  def piece(date, timepiece)
    return unless timepiece.gsub(/s$/, "").in?(TIMEPIECES)

    cast(date).send(timepiece)
  end

  def ago(num, interval)
    return unless interval.gsub(/s$/, "").in?(TIMEPIECES)

    @jil.cast(num, :Numeric).send(interval).ago
  end

  def from_now(num, interval)
    return unless interval.gsub(/s$/, "").in?(TIMEPIECES)

    @jil.cast(num, :Numeric).send(interval).from_now
  end

  def adjust(date, direction, duration)
    return unless direction.in?(["+", "-"])

    cast(date).send(direction, duration.to_f)
  end

  def add(date, num, timepiece)
    return unless timepiece.gsub(/s$/, "").in?(TIMEPIECES)

    cast(date) + @jil.cast(num, :Numeric).send(timepiece)
  end

  def subtract(date, num, timepiece)
    return unless timepiece.gsub(/s$/, "").in?(TIMEPIECES)

    cast(date) - @jil.cast(num, :Numeric).send(timepiece)
  end

  def round(date, direction, interval)
    date = cast(date)
    direction = direction.to_sym
    interval = interval.gsub(/s$/, "").to_sym

    return unless interval.to_s.in?(TIMEPIECES)
    return unless direction.in?([:beginning, :end, :nearest])

    if direction.to_sym == :nearest
      lower = TIMEPIECES[TIMEPIECES.index(interval.to_s)-1].to_sym
      maxes = {
        second: 60,
        minute: 60,
        hour: 24,
        day: 7,
        week: Date.new(date.year, date.month, -1).day,
        month: 12,
      }

      direction = date.send(lower) > maxes[lower]/2.to_f ? :end : :beginning
    end

    cast(date).send("#{direction}_of_#{interval}")
  end

  def format(date, str)
    cast(date).strftime(str.to_s)
  end
end

# [Date]::datetime-local
#   #new(Numeric:year Numeric:month Numeric:day Numeric:hour Numeric:min Numeric:sec)
#   #now
#   #ago(Numeric ["seconds" "minutes" "hours" "days" "weeks" "months" "years"])
#   #from_now(Numeric ["seconds" "minutes" "hours" "days" "weeks" "months" "years"])
#   .piece(["second" "minute" "hour" "day" "week" "month" "year"])::Numeric
#   .adjust(["+", "-"], Duration|Numeric)
#   .round("TO" ["beginning" "end" "nearest"] "OF" ["minute" "hour" "day" "week" "month" "year"])
#   .format(String)::String
