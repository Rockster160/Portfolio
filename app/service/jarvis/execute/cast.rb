class Jarvis::Execute::Cast < Jarvis::Execute::Executor
  def self.cast(val, to, force: false)
    return val if to.to_sym == :any

    if ::Jarvis::Execute::Raw::CASTABLE.include?(to.to_sym)
      return ::Jarvis::Execute::Raw.send(to.to_sym, val)
    elsif force
      case to.to_sym
      when :array
        return val.try(:to_a) || []
      when :hash
        return val.try(:to_h) || val.try(:to_json) || []
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
