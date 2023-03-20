class Jarvis::Execute::Cast < Jarvis::Execute::Executor
  def self.cast(val, to)
    return val if to.to_sym == :any

    if ::Jarvis::Execute::Raw::CASTABLE.include?(to.to_sym)
      return ::Jarvis::Execute::Raw.send(to.to_sym, val)
    end

    raise "Unknown type to cast: #{to.class}(#{to}): #{val}"
  end

  def cast
    val, to = evalargs

    self.class.cast(val, to)
  end
end
