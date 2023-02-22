class Jarvis::Execute::Array < Jarvis::Execute::Executor
  def get
    arr, idx = evalargs
    arr[idx]
  end

  def set
    arr, idx, val = evalargs
    arr[idx] = val
    arr
  end

  def del
    arr, idx = evalargs
    arr.dup.tap { |a| a.delete_at(idx) }
  end

  def min
    arr = evalargs.first
    arr.min
  end

  def max
    arr = evalargs.first
    arr.max
  end

  def sample
    arr = evalargs.first
    arr.sample
  end

  def prepend
    val, arr = evalargs.first
    arr.prepend(val)
  end

  def append
    arr, val = evalargs
    arr.append(val)
  end

  def length
    arr = evalargs.first
    arr.length
  end

  def join
    with, *vals = evalargs
    vals.join(with)
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

  # def find
  #   { return: :any, description: "First truthy value from array" },
  #   { block: :array },
  #   :content,
  # end

  # def find_map
  #   { return: :any, description: "First truthy return from array (the return, not the object)" },
  #   { block: :array },
  #   :content,
  # end

  # def merge
  #   { return: :array },
  #   { block: :array },
  #   { block: :array },
  # end

  # def each
  #   { return: :num }, # number of times the loop ran
  #   { block: :array },
  #   :content,
  # end

  # def map
  #   { return: :array },
  #   { block: :array },
  #   :content, # last value from content is used as new array value
  # end
  # def map
  #   loop_exit = false
  #   pre_key, pre_obj, pre_idx = jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] # save state
  #   arr, steps = args
  #
  #   vals = eval_block(arr).map.with_index do |(key, val), idx|
  #     jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = key, val, idx
  #     break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
  #
  #     val = steps.map { |arg|
  #       # next and break only break out of one layer
  #       case arg[:type].try(:to_sym)
  #       when :"logic.next"
  #         # Don't run any more steps in the block, but continue the loop
  #         break [eval_block(arg)] # still evaling here so that it increments
  #       when :"logic.break"
  #         loop_exit = true
  #         break [eval_block(arg)] # still evaling here so that it increments
  #       else
  #         eval_block(arg)
  #       end
  #     }.last
  #     break val if loop_exit
  #     val
  #   end
  #
  #   jil.ctx[:loop_key], jil.ctx[:loop_obj], jil.ctx[:loop_idx] = pre_key, pre_obj, pre_idx # reset state
  #   return vals
  # end
  # def each
  #   map
  # end
end
