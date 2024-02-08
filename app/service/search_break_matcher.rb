module SearchBreakMatcher
  module_function

  DELIMITERS = {
    contains:     ":",
    exact:        "::",
    not:          "!",
    not_contains: "!:",
    not_exact:    "!::",
    regex:        "~",
    or:           "OR",
    aliases: { # Figure out a way that allows an "aliases" delimiter. Just in case.
      or: "OR:", # Should probably reverse these so multiple aliases can point to one delim
    }
  }

  def call(str, data)
    breaker = SearchBreaker.call(str, DELIMITERS)

    return false if !data.is_a?(Hash) || data.keys.none?
    raise "Only 1 top level key allowed" unless data.keys.one?

    breaker_matches(breaker, data).any?
  rescue StandardError => e
    require "pry-rails"; binding.pry
  end
  # {data} -- ...key: key: key: "string"
  # data = { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }
  # {breaker} -- broken.keys & [:keys, :vals]
  #   keys: {{broken}, {broken}, ...}
  # {broken} -- broken.keys & [:contains, ...]
  #   {delim}: [{piece}, {piece}]
  # {delim} -- contains|exact|delims
  # {piece} -- [String, {breaker}]

  def breaker_matches(breaker, data, d=nil)
    if breaker.is_a?(String) && d.present?
      return valstr_match(breaker, d, data)
    end

    breaker[:keys].filter_map { |val, broken| # val="event" && broken[:contains] = [{piece}]
      broken.filter_map { |delim, piece|
        case piece
        when Array then piece.filter_map { |nested_breaker| breaker_matches(nested_breaker, data, delim) }
        else valstr_match(val, delim, data)
        end
      }
    }.flatten
  rescue StandardError => e
    require "pry-rails"; binding.pry
  end
  #
  # def data_next_match
  # end
  #
  # def next_broken_match(broken, datastr)
  # end

  # def broken_matches(broken, datastr)
  #   broken.select { |delim, piece|
  #     case piece
  #     when String then check_match?(piece, delim, datastr)
  #     when Hash
  #
  #     end
  #   }
  # end

  # def broken_matches(brokens, data)
  #   brokens = Array.wrap(brokens)
  #   case data
  #   when Hash
  #     brokens.filter_map { |broken|
  #       broken[:keys].filter_map { |val, nested_broken|
  #       }.flatten
  #       # data.filter_map { |datastr, nested_data|
  #       #   broken_match?(broken, datastr)
  #       #   # nested_broken = next_broken_match(broken, datastr)
  #       #   # return false unless nested_broken
  #       #   #
  #       #   # broken_match?(nested_broken, nested_data)
  #       # }
  #       # datastr, nested_data
  #       # broken_matches
  #       # nested_broken = next_broken_match(broken, datastr)
  #       # next unless nested_broken
  #       #
  #       # broken_match?(nested_broken, nested_data)
  #     }.flatten
  #   when Array then data.all? { |nested_data| broken_match?(broken, nested_data) }
  #   when String then next_broken_match(broken, data).any?
  #   end
  # end
  # # ====================================
  #
  # def unwrap(nested_broken, nested_data)
  #   case nested_data
  #   when String
  #   when Array
  #   end
  #   # return [nested_data, nested_broken]
  # end
  #
  # def next_broken_match(broken, data)
  #   case data
  #   when String then dig_broken(broken, data)
  #   end
  # end
  #
  # def dig_broken(broken, datastr)
  #   # nested {broken} after the datastr matches
  #   broken.all? { |delim_key, nested_broken|
  #     # return nested_broken
  #   }
  # end

  # "event:data:custom:nested_key:fuzzy_val"
  # { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }

  #      str = "event:name::food"
  #   broken = {contains: [{keys: {"name"=>{exact: ["food"]}}}]}
  # ❌  data = { name: "foo" }
  # ✅  data = { name: "food" }

  #      str = "event::workout"
  # ❌  data = { name: "hardworkout", notes: "Beat Saber" }
  # ✅  data = { name: "workout", notes: "Beat Saber" }

  #      str = "travel"
  # ❌  data = { name: "hardworkout", notes: "Beat Saber" }
  # ✅  data = { event: { name: "Life", notes: "Traveled to Rome" } }
  # ✅  data = { travel: { action: "departed", location: "Home" }

  # def match_broken?(broken, data)
  #   broken.all? { |bkey, array|
  #     next false unless DELIMITERS.keys.include?(bkey)
  #
  #     array.all? { |val|
  #       # If a hash, it should be {breaker}
  #       # Otherwise should be a string that can be matched directly against
  #       val.is_a?(Hash) ? breaker_match?(val, bkey, data) : valstr_match(val, bkey, data)
  #     }
  #     # find_nested(array, bkey, key)
  #   }
  # end
  #
  # def breaker_match?(breaker, delim, data)
  #   breaker[:keys].all? { |val, broken|
  #     valstr_match(val, delim, data) || broken_match?(broken, delim, data)
  #   }
  # end
  #
  # def nested_match?(broken, delim, data)
  #   # {:keys=>
  #   #   {"event"=>                          ← Here!
  #   #     {:contains=>
  #   #       [{:keys=>
  #   #          {"data"=>                    ← Here!
  #   #            {:contains=>
  #   #              [{:keys=>
  #   #                {"custom"=>            ← Here!
  #   #                  {:contains=>
  #   #                    [{:keys=>
  #   #                      {"nested_key"=>  ← Here!
  #   #                        {:contains=>
  #   #                          ["fuzzy_val"]}}}]}}}]}}}]}}}
  #   # broken[:keys].all? { |bkey, nested_broken|
  #   #   valstr_match(, delim, data)
  #   # }
  # end
  #
  # #
  # # def find_nested(broken, delim, data)
  # #   broken[:keys].find { |bkey, bval|
  # #     # bval is a hash with string keys
  # #     # bval.
  # #     # return bval[matching_key] # -- {breaker}
  # #   }
  # # end
  #
  def valstr_match(val, delim, data) # val is a bottom-level string from the {broken} data
    return check_match?(val, delim, data) && data if data.is_a?(String)

    # Return back the first object that matches -- Might need to return the nested object?
    data&.find { |dkey, dvals|
      case dvals
      when Hash
        dvals.find { |k,v|
          check_match?(val, delim, k) || valstr_match(val, delim, v)
        }
      when Array
        dvals.find { |dv| valstr_match(val, delim, dv) }
      when String # string to string -- Check if they match according to the delim
        check_match?(val, delim, dvals) && dvals
      else
        require "pry-rails"; binding.pry
      end
    } || false
  rescue StandardError => e
    require "pry-rails"; binding.pry
  end

  def check_match?(val, delim, str)
    str = str.to_s
    case delim
    when :contains then val.include?(str)
    when :not_contains then !val.include?(str)
    when :exact then val == str
    when :not, :not_exact then val != str
    # when :regex then str.match?(regex)
    else false
    end
  rescue StandardError => e
    require "pry-rails"; binding.pry
  end
end
