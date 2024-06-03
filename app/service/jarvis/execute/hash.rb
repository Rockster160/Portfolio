class Jarvis::Execute::Hash < Jarvis::Execute::Executor
  def cast
    eval_block(args).to_h
  end

  def get
    hash, key = evalargs
    hash = BetterJsonSerializer.load(hash).with_indifferent_access
    hash[key]
  end

  def set
    hash, key, val = evalargs
    hash = BetterJsonSerializer.load(hash).with_indifferent_access
    hash[key] = val
    hash
  end

  def del
    hash, key = evalargs
    hash = BetterJsonSerializer.load(hash).with_indifferent_access
    hash.delete(key)
    hash
  end

  def keys
    hash = evalargs
    hash = BetterJsonSerializer.load(hash)
    hash.keys
  end

  def length
    hash = evalargs
    hash = BetterJsonSerializer.load(hash)
    hash.keys.length
  end

  def merge
    hash1, hash2 = evalargs
    hash1 = BetterJsonSerializer.load(hash1)
    hash2 = BetterJsonSerializer.load(hash2)
    hash1.merge(hash2)
  end

  def map
    loop_exit = false
    pre_key, pre_obj, pre_idx = jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] # save state
    hash, steps = args
    hash = BetterJsonSerializer.load(hash)

    vals = eval_block(hash).map.with_index do |(key, val), idx|
      jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = key, val, idx
      break if loop_exit || jil.ctx[:i] > Jarvis::Execute::MAX_ITERATIONS

      val = steps.map { |arg|
        break [] if jil.ctx[:exit]
        # next and break only break out of one layer
        case arg[:type].try(:to_sym)
        when :"logic.next"
          # Don't run any more steps in the block, but continue the loop
          break [eval_block(arg)] # still evaling here so that it increments
        when :"logic.break"
          loop_exit = true
          break [eval_block(arg)] # still evaling here so that it increments
        when :"task.exit"
          loop_exit = true
          break [eval_block(arg)] # still evaling here so that it increments
        else
          eval_block(arg).tap { |arg_val|
            break arg_val if jil.ctx.delete(:next)
            if jil.ctx.delete(:break)
              loop_exit = true
              break arg_val
            end
          }
        end
      }.last
      break val if loop_exit || jil.ctx.delete(:break)
      val
    end

    jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = pre_key, pre_obj, pre_idx # reset state
    return vals
  end
  def each
    map.count
  end
end
