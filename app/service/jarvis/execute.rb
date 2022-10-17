class Jarvis::Execute
  MAX_ITERATIONS = 1000

  def self.call(task)
    new.call(task)
  end

  def call(task)
    @task = task
    @ctx = { vars: {}, i: 0, msg: [], loop_idx: nil, loop_obj: nil }
    task.next_trigger_at = Fugit::Cron.parse(task.cron).next_time if task.cron.present?
    task.update(last_trigger_at: Time.current)

    task.tasks.each_with_index do |task_block, idx|
      break if @ctx[:i] >= MAX_ITERATIONS
      break if @ctx[:exit]

      eval_block(task_block.deep_symbolize_keys)
    end
    if @ctx[:i] > MAX_ITERATIONS
      raise StandardError, "Blocks exceed #{ActiveSupport::NumberHelper.number_to_delimited(MAX_ITERATIONS)} allowed."
    end
    @ctx[:msg] << "Success"
    # Trigger success?
  rescue StandardError => e
    @ctx[:msg] << "Failed: #{e.message}"
    # Jil should have an interface / logger that displays all recent task runs and failure messages
    # trigger fail unless task has a fail trigger
  ensure
    @task.update(last_result: @ctx[:msg].join("\n"), last_ctx: @ctx)
    @ctx[:msg]#.join("\n")
  end

  def eval_block(task_block, scope_ctx={})
    return task_block.each { |sub_block| eval_block(sub_block) } && nil if task_block.is_a?(Array)
    @ctx[:i] += 1
    return if @ctx[:i] > MAX_ITERATIONS
    return task_block if [true, false, nil].include?(task_block)
    return task_block if task_block.class.in?([String, Integer, Float])

    case task_block[:type].to_sym
      # LOGIC
    when :if
      eval_block(eval_block(task_block[:condition]) ? task_block[:do] : task_block[:else])
    when :and
      task_block[:args].all? { |a| eval_block(a) }
    when :or
      task_block[:args].any? { |a| eval_block(a) }
    when :compare
      return unless task_block[:sign].in?(["==", "!=", "<", "<=", ">", ">="])
      a, b = task_block[:args].first(2).map { |a| eval_block(a) }
      a.send(task_block[:sign], b)
    when :not
      !eval_block(task_block[:arg])
      # MATH
    when :operation
      return unless task_block[:op].in?(["+", "-", "*", "/", "%"])
      c, *rest = task_block[:args]
      rest.each_with_object(eval_block(c)) { |a, pass| pass.send(task_block[:op], eval_block(a)) }
    when :adv_ops
      case task_block[:op].to_sym
      when :abs then task_block[:value].try(:abs)
      when :sqrt then Math.sqrt(task_block[:value])
      end
    # when :math_check
      # {
      #   type: :math_check,
      #   op: "even", # even odd prime whole positive negative divisblebyX
      #   value: NUM
      # }
    when :random then rand
    when :round then task_block[:value].round
      # VALUES
    when :bool then !!eval_block(task_block[:value])
    when :string then eval_block(task_block[:value]).to_s
    when :integer then eval_block(task_block[:value]).to_i
    when :float then eval_block(task_block[:value]).to_f
    when :index then @ctx[:loop_idx]
    when :object then (@ctx[:loop_obj] || @ctx[:loop_idx])
      # Array and dict?
      # VARIABLES
    when :get_var then @ctx.dig(:vars, task_block[:name])
    when :set_var then @ctx[:vars][task_block[:name]] = eval_block(task_block[:value])
      # TOP LEVEL?
    when :next, :break then nil
    when :exit
      @ctx[:exit] = true
      @ctx[:msg] << eval_block(task_block[:reason]) || "Exit"
    when :print
      @ctx[:msg] << eval_block(task_block[:message])
    when :say
      @ctx[:msg] << Jarvis.command(@task.user, eval_block(task_block[:message]))
      # LOOPS
    when :each, :map
      loop_exit = false

      pre_idx, pre_obj = @ctx[:loop_idx], @ctx[:loop_obj]
      task_block[:do].map.with_index do |a, i|
        @ctx[:loop_idx], @ctx[:loop_obj] = a, i
        break if loop_exit || @ctx[:i] > MAX_ITERATIONS
        next (@ctx[:i] += 1 && nil) if a[:type]&.to_sym == :next
        break (loop_exit = true && nil) if a[:type]&.to_sym == :break # Stop entire loop
        next eval_block(i) if a[:type]&.to_sym == :index

        eval_block(a)
      end
      @ctx[:loop_idx], @ctx[:loop_obj] = pre_idx, pre_obj
    when :loop
      loop_exit = false

      pre_idx, pre_obj = @ctx[:loop_idx], @ctx[:loop_obj]
      task_block[:times].to_i.clamp(..MAX_ITERATIONS).times do |i|
        @ctx[:loop_idx] = i
        break if loop_exit || @ctx[:i] > MAX_ITERATIONS
        break unless task_block[:do]&.any?

        task_block[:do].each do |a|
          break if loop_exit || @ctx[:i] > MAX_ITERATIONS
          break if a[:type]&.to_sym == :next # Only break out of the "each", effectively being a next
          break loop_exit = true if a[:type]&.to_sym == :break # Stop entire loop
          next eval_block(i) if a[:type]&.to_sym == :index || a[:type]&.to_sym == :object

          eval_block(a)
        end
      end
      @ctx[:loop_idx], @ctx[:loop_obj] = pre_idx, pre_obj
    when :while
      loop_exit = false
      i = -1
      loop do
        @ctx[:loop_idx] = i += 1
        break if loop_exit || @ctx[:i] > MAX_ITERATIONS
        break unless eval_block(task_block[:condition])
        break unless task_block[:do]&.any?

        task_block[:do].each do |a|
          break if loop_exit || @ctx[:i] > MAX_ITERATIONS
          break if a[:type]&.to_sym == :next # Only break out of the "each", effectively being a next
          break loop_exit = true if a[:type]&.to_sym == :break # Stop entire loop
          next eval_block(i) if a[:type]&.to_sym == :index || a[:type]&.to_sym == :object

          eval_block(a)
        end
      end
    end
  end
end
