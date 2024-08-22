class Jil::Methods::Date < Jil::Methods::Base
  def cast(value)
    case value
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
end

# [Date]::datetime-local
#   #new(Numeric:year Numeric:month Numeric:day Numeric:hour Numeric:min Numeric:sec)
#   #now
#   .piece(["second" "minute" "hour" "day" "week" "month" "year"])::Numeric
#   .adjust(["+", "-"], Duration|Numeric)
#   .round("TO" ["beginning" "end"] "OF" ["second" "minute" "hour" "day" "week" "month" "year"])
#   .format(String)::String
