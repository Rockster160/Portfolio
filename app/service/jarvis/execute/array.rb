class Jarvis::Execute::Array < Jarvis::Execute::Executor
  def cast
    SafeJsonSerializer.load(eval_block(args))
  end

  def get
    arr, idx = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr[idx.to_i] # to_i is a hack because for some reason we're not evaling the evalargs
  end

  def set
    arr, idx, val = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr[idx.to_i] = val # to_i is a hack because for some reason we're not evaling the evalargs
    arr
  end

  def del
    arr, idx = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.dup.tap { |a| a.delete_at(idx) }
  end

  def includes
    arr, val = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.include?(val)
  end

  def min
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.min
  end

  def max
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.max
  end

  def sample
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.sample
  end

  def prepend
    val, arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.prepend(val)
  end

  def append
    arr, val = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.append(val)
  end

  def length
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.length
  end

  def sum
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.sum
  end

  def join
    with, *vals = evalargs
    vals.join(with)
  end

  def map
    loop_exit = false
    pre_key, pre_obj, pre_idx = jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] # save state
    arr, steps = args
    arr = SafeJsonSerializer.load(arr)

    vals = eval_block(arr).map.with_index do |val, idx|
      jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = idx, val, idx
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

  # def sort
  # - Fail for incompatible types
  #   { return: :array },
  #   { block: :array },
  #   [:asc, :desc, :random]
  # end

  # def sort_by
  #   { return: :array },
  #   { block: :array },
  #   :content, # last value from content is used to sort asc
  # end

  def find
    loop_exit = false
    pre_key, pre_obj, pre_idx = jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] # save state
    arr, steps = args
    arr = SafeJsonSerializer.load(arr)

    found = eval_block(arr).find.with_index do |val, idx|
      jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = idx, val, idx
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
    return found
  end

  def any?
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.any?
  end

  def none?
    !any?
  end

  def all?
    arr = evalargs
    arr = SafeJsonSerializer.load(arr)
    arr.all?
  end

  # def merge
  #   { return: :array },
  #   { block: :array },
  #   { block: :array },
  # end
end
