class Jarvis::Execute::Hash < Jarvis::Execute::Executor
  def get
    hash, key = evalargs
    hash.with_indifferent_access[key]
  end

  def set
    hash, key, val = evalargs
    hash.with_indifferent_access[key] = val
    hash
  end

  def del
    hash, key = evalargs
    hash.with_indifferent_access.delete(key)
    hash
  end

  def keys
    hash = evalargs
    hash.keys
  end

  def length
    hash = evalargs
    hash.keys.length
  end

  def merge
    hash1, hash2 = evalargs
    hash1.merge(hash2)
  end

  def map
    loop_exit = false
    pre_key, pre_obj, pre_idx = jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] # save state
    arr, steps = args

    vals = eval_block(arr).map.with_index do |(key, val), idx|
      jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = key, val, idx
      break if loop_exit || jil.ctx[:i] > Jarvis::Execute::MAX_ITERATIONS

      val = steps.map { |arg|
        # next and break only break out of one layer
        case arg[:type].try(:to_sym)
        when :"logic.next"
          # Don't run any more steps in the block, but continue the loop
          break [eval_block(arg)] # still evaling here so that it increments
        when :"logic.break"
          loop_exit = true
          break [eval_block(arg)] # still evaling here so that it increments
        else
          eval_block(arg)
        end
      }.last
      break val if loop_exit
      val
    end

    jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = pre_key, pre_obj, pre_idx # reset state
    return vals
  end
  def each
    map
  end
end
