 class Jarvis::Execute
  MAX_ITERATIONS = 1000
  attr_accessor :ctx, :task, :data

  def self.call(task, data={})
    new(task, data).call
  end

  def self.call_with_data(task, data={})
    new(task, data).then { |exe|
      exe.call
      [exe.ctx, exe.task, exe.data]
    }
  end

  def initialize(task, data={})
    @task = task
    @data = data
  end

  def call
    MonitorChannel.started(task) if task.monitor?
    @test_mode = data.delete(:test_mode)
    @ctx = { vars: {}, i: 0, msg: [], loop_idx: nil, loop_obj: nil, current_token: nil }
    @ctx.merge!(@data[:ctx] || {})
    task.update(last_trigger_at: Time.current)

    task.tasks&.each_with_index do |task_block, idx|
      next if task_block[:comment]
      break if @ctx[:i] >= MAX_ITERATIONS
      break if @ctx[:exit]

      eval_block(task_block.deep_symbolize_keys)
    end
    if @ctx[:i] > MAX_ITERATIONS
      raise StandardError, "Blocks exceed #{ActiveSupport::NumberHelper.number_to_delimited(MAX_ITERATIONS)} allowed."
    end
    @ctx[:msg] << @ctx[:last_val] if @ctx[:msg].none?
    @ctx[:msg]
    # Trigger success?
  rescue StandardError => e
    Rails.logger.error("\e[31m#{e.class}: #{e}\n#{e.backtrace.select{|l|l.include?("/app/")}.reverse.join("\n")}\e[0m")
    @ctx[:msg] << "[#{@ctx[:current_token]}] Failed: #{e.try(:message) || e.try(:body) || e}"
    # Jil should have an interface / logger that displays all recent task runs and failure messages
    # trigger fail unless task has a fail trigger
    SlackNotifier.err(e, "Jil Error[#{task.name}]")
    @ctx[:msg]
  ensure
    sleep 0.2 if @test_mode
    @task.user.current_usage.increment(@task, @ctx[:i])
    ActionCable.server.broadcast("jil_#{@task.uuid}_channel", { done: true, output: @ctx[:msg].join("\n") })
    @task.update(last_result: @ctx[:msg].join("\n"), last_ctx: @ctx, last_result_val: @ctx[:last_val])
    MonitorChannel.send_task(@task) if @task.monitor?
    @ctx[:msg]#.join("\n")
  end

  def lookup_option(option)
    @ctx[:vars].key?(option) ? @ctx[:vars][option] : option
  end

  def eval_block(task_block)
    if task_block.is_a?(::Hash) && task_block[:token].present?
      @ctx[:current_token] = task_block[:token]
      ActionCable.server.broadcast("jil_#{@task.uuid}_channel", { token: task_block[:token] })
      sleep 0.2 if @test_mode
    end
    if task_block.is_a?(::Array)
      if task_block.any? { |sub_block| sub_block.is_a?(::Hash) && sub_block[:returntype] == "keyval" }
        return task_block.each_with_object({}) { |sub_block, obj|
          k, v = eval_block(sub_block)
          k, v = nil, k if v.nil?
          k ||= sub_block[:token] || v
          obj[k] = v
        }
      else
        return task_block.map { |sub_block| eval_block(sub_block) }.last
      end
    end
    # return task_block if [true, false, nil].include?(task_block)
    # return task_block if task_block.class.in?([::String, ::Integer, ::Float])
    return task_block unless task_block.is_a?(::Hash)
    return raw_val(task_block) if task_block[:option] == "input"
    return lookup_option(task_block[:option]) if task_block[:option].present?
    @ctx[:i] += 1
    # Instead, this should raise an error so we don't have the weird off-by-one issue
    return if @ctx[:i] > MAX_ITERATIONS
    # Empty block
    if task_block.keys.sort == [:option, :selected].sort
      return if task_block.values.all?(&:blank?)
    end
    return task_block if task_block[:type].nil?

    klass, method = task_block[:type].split(".", 2)
    method = "logic_#{method}" if klass == "logic"

    @ctx[:vars][task_block[:token]] = (
      "Jarvis::Execute::#{klass.titleize.gsub(" ", "")}".constantize.new(self, task_block).send(method)
    ).then { |res|
      ::Jarvis::Execute::Cast.cast(res, task_block[:returntype], force: true, jil: self)
    }.tap { |res|
      ActionCable.server.broadcast("jil_#{@task.uuid}_channel", { token: task_block[:token], res: res.as_json })
      @ctx[:last_val] = res
    }.tap { |res|
      # binding.pry if @task.id == 43
      # binding.pry if task_block[:token] == "funky.saloon.oak"
      # binding.pry if task_block[:type] == "task.print"
    }
  # rescue StandardError => e
  #   binding.pry
  #   raise e
  end

  def raw_val(task_block)
    ::Jarvis::Execute::Cast.cast(task_block[:raw], :str, force: true, jil: self)
  end
end
