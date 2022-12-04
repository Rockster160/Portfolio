class Jarvis::Execute::Raw < Jarvis::Execute::Executor

  [:bool, :str, :num].each do |method|
    define_method(method) do
      self.class.send(method, args)
    end
  end

  def self.bool(val)
    !!val
  end

  def self.str(val)
    val.to_s
  rescue NoMethodError
    ""
  end

  def self.num(val)
    val.to_i == val.to_f ? val.to_i : val.to_f
  rescue NoMethodError
    0
  end

  def get_var
  end

  def clone_var
  end

  def set_var
  end

  def get_cache
  end

  def set_cache
  end
end
