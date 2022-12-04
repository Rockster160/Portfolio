class Jarvis::Execute
  MAX_ITERATIONS = 1000
  include CallableService
  init_attrs :task, data: {}
  attr_accessor :ctx

  def call
    # Can call another Task, but carry @ctx (especially i)
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

  def eval_block(task_block)
    return task_block.map { |sub_block| eval_block(sub_block) }.last if task_block.is_a?(Array)
    return task_block if [true, false, nil].include?(task_block)
    return task_block if task_block.class.in?([String, Integer, Float])
    @ctx[:i] += 1
    # Instead, this should raise an error so we don't have the weird off-by-one issue
    return if @ctx[:i] > MAX_ITERATIONS

    klass, method = task_block[:type].split(".")
    method = "logic_#{method}" if klass == "logic"
    "Jarvis::Execute::#{klass.titleize}".constantize.new(self, task_block).send(method)
  end
end
