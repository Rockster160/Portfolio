class Jarvis::Execute::Raw < Jarvis::Execute::Executor
  CASTABLE = [:bool, :str, :text, :num]
  # TODO: cast date

  CASTABLE.each do |method|
    define_method(method) do
      self.class.send(method, args, @jil)
    end
  end

  def self.bool(val, jil=nil)
    case val
    when ::Array then bool(val.first.try(:dig, :raw))
    when ::Hash then bool(val[:raw])
    when ::String then !val.match?(/^(0|f|false|falsy|no)$/i)
    else
      !!val
    end
  end

  def self.text(val, jil=nil)
    str(val, jil)
  end

  def self.str(val, jil=nil)
    case val
    when ::Array then str((val.one? && val.first.try(:dig, :raw)) || val.to_json)
    when ::Hash then str(val[:raw] || val.to_json)
    else
      val.to_s
    end.then { |solved_str|
      solved_str.gsub(/#\{\s*(.*?)\s*\}/) do |found|
        token = Regexp.last_match[1]
        vars = jil&.ctx&.dig(:vars) || {}
        token_val = vars[token]
        token_val ||= vars.find { |k, v|
          token.downcase.gsub(/\:var$/, "") == k.downcase.gsub(/\:var$/, "")
        }&.dig(1)
        if token_val.nil?
          jil.ctx[:msg] << "Unfound token (#{token})"
        end
        token_val
      end
    }
  rescue NoMethodError
    ""
  end

  def self.num(val, jil=nil)
    casted = case val
    when ::Array then (val.one? && num(val.first.try(:dig, :raw))) || raise("Unable to cast <Array> to <Num>")
    when ::Hash then val[:raw].present? ? num(val[:raw]) : raise("Unable to cast <Hash> to <Num>")
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
    key = evalargs

    user_cache.get(eval_block(key))
  end

  def set_cache
    key, val = evalargs

    # TODO: Should NOT be able to set complex objects...
    user_cache.set(eval_block(key), eval_block(val))
  end

  def user_cache
    @user_cache ||= user.jarvis_cache
  end
end
