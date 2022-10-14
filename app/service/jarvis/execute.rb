class Jarvis::Execute
  def self.call(task)
    new.call(task)
  end

  def call(task)
    @task = task
    @ctx = { vars: {}, i: 0, msg: [] }
    task.next_trigger_at = Fugit::Cron.parse(task.cron).next_time if task.cron.present?
    task.update(last_trigger_at: Time.current)

    task.tasks.each do |task_block|
      break @ctx[:msg] << "Overflow - only 1,000 iterations allowed." if @ctx[:i] > 1000
      break if @ctx[:exit]

      eval_block(task_block.deep_symbolize_keys)
    end
    @ctx[:msg] << "Success"
    # Trigger success?
  rescue StandardError => e
    @ctx[:msg] << "Failed: #{e.message}"
    # trigger fail unless task has a fail trigger
  ensure
    @task.update(last_result: @ctx[:msg].join("\n"), last_ctx: @ctx)
    @ctx[:msg]#.join("\n")
  end

  def eval_block(task_block, scope_ctx={})
    return if @ctx[:i] > 1000
    return task_block if [true, false, nil].include?(task_block)
    return task_block if task_block.class.in?([String, Integer, Float])
    return task_block.each { |sub_block| eval_block(sub_block) } && nil if task_block.is_a?(Array)
    @ctx[:i] += 1

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
      # LOOPS
    when :loop
      loop_exit = false
      task_block[:times].to_i.times do |i|
        break if loop_exit || @ctx[:i] > 1000
        task_block[:do].each do |a|
          break if loop_exit || @ctx[:i] > 1000
          break if a[:type].to_sym == :next # Only break out of the "each", effectively being a next
          break loop_exit = true if a[:type].to_sym == :break # Stop entire loop

          eval_block(a)
        end
      end
    when :while
      loop_exit = false
      loop do
        break if loop_exit || @ctx[:i] > 1000
        break unless eval_block(task_block[:condition])

        task_block[:do].each do |a|
          break if loop_exit || @ctx[:i] > 1000
          break if a[:type].to_sym == :next # Only break out of the "each", effectively being a next
          break loop_exit = true if a[:type].to_sym == :break # Stop entire loop

          eval_block(a)
        end
      end
    end
  end
end
