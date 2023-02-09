class Jarvis::Execute
  MAX_ITERATIONS = 1000
  attr_accessor :ctx, :task, :data

  def self.call(task, data={})
    new(task, data).call
  end

  def initialize(task, data={})
    @task = task
    @data = data
  end

  def call
    @test_mode = data.delete(:test_mode)
    # Can call another Task, but carry @ctx (especially i)
    @ctx = { vars: {}, i: 0, msg: [], loop_idx: nil, loop_obj: nil, current_token: nil }
    task.next_trigger_at = CronParse.next(task.cron) if task.cron.present?
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
    Rails.logger.error("\e[31m#{e.class}: #{e}\n#{e.backtrace.select{|l|l.include?("/app/")}.reverse.join("\n")}\e[0m")
    @ctx[:msg] << "[#{@ctx[:current_token]}] Failed: #{e.message}"
    # Jil should have an interface / logger that displays all recent task runs and failure messages
    # trigger fail unless task has a fail trigger
  ensure
    sleep 0.2 if @test_mode
    ActionCable.server.broadcast("jil_#{@task.id}_channel", { done: true, output: @ctx[:msg].join("\n") })
    @task.update(last_result: @ctx[:msg].join("\n"), last_ctx: @ctx)
    @ctx[:msg]#.join("\n")
  end

  def lookup_option(option)
    @ctx[:vars].key?(option) ? @ctx[:vars][option] : option
  end

  def eval_block(task_block)
    if task_block.is_a?(::Hash) && task_block[:token].present?
      @ctx[:current_token] = task_block[:token]
      ActionCable.server.broadcast("jil_#{@task.id}_channel", { token: task_block[:token] })
      sleep 0.2 if @test_mode
    end
    return task_block.map { |sub_block| eval_block(sub_block) }.last if task_block.is_a?(::Array)
    return task_block if [true, false, nil].include?(task_block)
    return task_block if task_block.class.in?([::String, ::Integer, ::Float])
    return raw_val(task_block) if task_block[:option] == "input"
    return lookup_option(task_block[:option]) if task_block[:option].present?
    @ctx[:i] += 1
    # Instead, this should raise an error so we don't have the weird off-by-one issue
    return if @ctx[:i] > MAX_ITERATIONS
    return if task_block[:type].nil?

    klass, method = task_block[:type].split(".")
    method = "logic_#{method}" if klass == "logic"

    @ctx[:vars][task_block[:token]] = (
      "Jarvis::Execute::#{klass.titleize.gsub(" ", "")}".constantize.new(self, task_block).send(method)
    ).tap { |res|
      ActionCable.server.broadcast("jil_#{@task.id}_channel", { token: task_block[:token], res: res })
    }
  # rescue StandardError => e
  #   binding.pry
  #   raise e
  end

  def raw_val(task_block)
    task_block[:raw]
  end
end
