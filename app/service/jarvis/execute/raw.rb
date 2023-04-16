class Jarvis::Execute::Raw < Jarvis::Execute::Executor
  CASTABLE = [:bool, :str, :num]
  # TODO: cast date

  CASTABLE.each do |method|
    define_method(method) do
      self.class.send(method, args)
    end
  end

  def self.bool(val)
    case val
    when ::Array then val.first.try(:dig, :raw)
    when ::Hash then val[:raw]
    when ::String then !val.match?(/^(0|f|false|falsy|no)$/i)
    else
      !!val
    end
  end

  def self.str(val)
    case val
    when ::Array then (val.one? && val.first.try(:dig, :raw)) || val.to_json
    when ::Hash then val[:raw] || val.to_json
    else
      val.to_s
    end
  rescue NoMethodError
    ""
  end

  def self.num(val)
    casted = case val
    when ::Array then (val.one? && val.first.try(:dig, :raw)) || raise("Unable to cast <Array> to <Num>")
    when ::Hash then val[:raw] || raise("Unable to cast <Hash> to <Num>")
    when ::TrueClass then 1
    else
      val
    end
    casted.to_i == casted.to_f ? casted.to_i : casted.to_f
  rescue NoMethodError
    0
  end

  def keyval
    key, val = evalargs
    [key, val]
  rescue NoMethodError
    [nil, nil]
  end

  def hash
    evalargs.each_with_object({}) do |(key, val), new_hash|
      new_hash[key] = val
    end
  rescue NoMethodError
    {}
  end

  def array
    evalargs
  rescue NoMethodError
    []
  end

  def get_var
    jil.ctx.dig(:vars, eval_block(args))
  end

  def set_var
    name, value = args.map { |arg| eval_block(arg) }
    jil.ctx[:vars][name] = eval_block(value)
  end

  def get_cache
    str = evalargs

    user_cache.get(eval_block(str))
  end

  def set_cache
    str, val = evalargs

    # TODO: Should NOT be able to set complex objects...
    user_cache.set(eval_block(str), eval_block(val))
  end

  def user_cache
    @user_cache ||= user.jarvis_cache || user.create_jarvis_cache
  end
end
