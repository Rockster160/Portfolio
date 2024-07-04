class Jarvis::Execute::Logic < Jarvis::Execute::Executor
  MAX_ITERATIONS = Jarvis::Execute::MAX_ITERATIONS

  def logic_if
    task_cond, task_do, task_else = args
    eval_block(eval_block(task_cond).present? ? task_do : task_else)
  end

  def logic_and
    evalargs.inject(nil) { |memo, t| memo && eval_block(t).presence }
  end

  def logic_or
    evalargs.inject(nil) { |memo, t| memo || eval_block(t).presence }
  end

  def logic_eq
    evalargs.inject(:==)
  end

  def logic_not
    !eval_block(args.first)
  end

  def logic_index
    jil.ctx[:loop_idx]
  end

  def logic_key
    jil.ctx[:loop_key]
  end

  def logic_object
    (jil.ctx[:loop_obj] || jil.ctx[:loop_idx])
  end

  def logic_next
    jil.ctx[:next] = true
    evalargs # No-op - just return what's put in
  end
  def logic_break
    jil.ctx[:break] = true
    evalargs # No-op - just return what's put in
  end

  def logic_exit
    jil.ctx[:exit] = true
    jil.ctx[:msg] << ::Jarvis::Execute::Raw.str(evalargs || "Exit")
  end

  def logic_map
    loop_exit = false
    pre_idx, pre_obj = jil.ctx[:loop_idx], jil.ctx[:loop_obj] # save state
    arr, steps = args

    vals = eval_block(arr).map.with_index do |item, idx|
      jil.ctx[:loop_obj], jil.ctx[:loop_idx] = item, idx
      break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS

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

    jil.ctx[:loop_idx], jil.ctx[:loop_obj] = pre_idx, pre_obj # reset previous state
    return vals
  end
  def logic_each
    logic_map
  end

  def logic_loop
    loop_exit = false
    pre_idx, pre_obj = jil.ctx[:loop_idx], jil.ctx[:loop_obj] # save state

    i = -1
    loop do
      break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
      break unless args&.any?
      jil.ctx[:loop_idx] = i += 1

      args.each do |arg|
        break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
        case arg[:type].try(:to_sym)
        when :"logic.next"
          # Don't run any more steps in the block, but continue the loop
          # Only breaks out of the "each", effectively being a next
          break eval_block(arg) # still evaling here so that it increments
        when :"logic.break"
          loop_exit = true
          break eval_block(arg) # still evaling here so that it increments
        end

        eval_block(arg)
      end
    end

    jil.ctx[:loop_idx], jil.ctx[:loop_obj] = pre_idx, pre_obj # reset previous state
    return i
  end

  def logic_times
    loop_exit = false
    pre_idx, pre_obj = jil.ctx[:loop_idx], jil.ctx[:loop_obj] # save state
    max_times, steps = args
    max_times = Jarvis::Execute::Raw.num(eval_block(max_times))

    i = -1
    loop do
      break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
      break unless steps&.any?
      jil.ctx[:loop_idx] = i += 1
      break if i >= max_times

      steps.each do |arg|
        break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
        case arg[:type].try(:to_sym)
        when :"logic.next"
          # Don't run any more steps in the block, but continue the loop
          # Only breaks out of the "each", effectively being a next
          break eval_block(arg) # still evaling here so that it increments
        when :"logic.break"
          loop_exit = true
          break eval_block(arg) # still evaling here so that it increments
        end

        eval_block(arg)
      end
    end

    jil.ctx[:loop_idx], jil.ctx[:loop_obj] = pre_idx, pre_obj # reset previous state
    return i
  end

  def logic_while
    loop_exit = false
    pre_idx, pre_obj = jil.ctx[:loop_idx], jil.ctx[:loop_obj] # save state

    i = -1
    loop do
      break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
      break unless args&.any?
      jil.ctx[:loop_idx] = i += 1
      break if i >= max_times

      args.each do |arg|
        break if loop_exit || jil.ctx[:i] > MAX_ITERATIONS
        case arg[:type].try(:to_sym)
        when :"logic.next"
          # Don't run any more steps in the block, but continue the loop
          # Only breaks out of the "each", effectively being a next
          break eval_block(arg) # still evaling here so that it increments
        when :"logic.break"
          loop_exit = true
          break eval_block(arg) # still evaling here so that it increments
        end

        loop_exit = true if eval_block(arg)
      end
    end

    jil.ctx[:loop_idx], jil.ctx[:loop_obj] = pre_idx, pre_obj # reset previous state
    return i
  end
end
