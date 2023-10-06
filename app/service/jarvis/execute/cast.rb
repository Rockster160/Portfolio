class Jarvis::Execute::Cast < Jarvis::Execute::Executor
  FORCE_CASTABLE = ::Jarvis::Execute::Raw::CASTABLE + [:array, :hash, :date]

  def self.cast(val, to, force: false, jil: nil)
    return val if to.to_sym == :any

    if ::Jarvis::Execute::Raw::CASTABLE.include?(to.to_sym)
      return ::Jarvis::Execute::Raw.send(to.to_sym, val, jil)
    elsif force
      case to.to_sym
      when :array
        return val.try(:to_a) || []
      when :hash
        return val.try(:to_h) || val.try(:to_json) || []
      when :date
        return val.to_datetime
      else
        return val
      end
    end

    raise "Unknown type to cast: #{to.class}(#{to}): #{val}"
  end

  def cast
    val, to = evalargs

    self.class.cast(val, to)
  end
end
