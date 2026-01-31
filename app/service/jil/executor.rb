class Jil::Executor
  attr_accessor :user, :ctx, :lines, :input_data, :task, :execution, :broadcast_task

  # def self.async_trigger(user, trigger, trigger_data={}, at: nil)
  #   ::User.ids(user).each do |user_id|
  #     ::ScheduledTrigger.create!(
  #       user_id: user_id,
  #       execute_at: at || ::Time.current,
  #       trigger: trigger,
  #       data: ::Trigger.parse_trigger_data(trigger_data),
  #     )
  #   end

  #   if at.blank?
  #     ::JilTriggerWorker.perform_async(user_ids, trigger, trigger_data)
  #   else
  #     ::Jil::Schedule.add_schedules(user_ids, at, trigger, trigger_data)
  #   end
  # end

  def self.trigger(user, trigger, raw_trigger_data={})
    if trigger.blank?
      lines = caller.select { |line|
        line.include?(Rails.root.to_s) || line.include?("_scripts")
      }.map { |line|
        line.gsub(/^.*?#{Rails.root}/, "").gsub(/(app)?\/app\//, "app/").gsub(":in `", " `").gsub(
          /(:\d+) .*?$/, '\1'
        )
      }.join("\n")
      msg = "No trigger:```\n#{lines}\n```"
      msg += "\n\n```\n#{JSON.pretty_generate(raw_trigger_data)}\n```" if raw_trigger_data.present?
      SlackNotifier.notify(msg)
      return
    end

    ::Jarvis.log("\e[35m[#{trigger}] \e[0m" + PrettyLogger.truncate(
      PrettyLogger.pretty_message({ trigger => raw_trigger_data }), 1000
    ))

    trigger_data = TriggerData.parse(raw_trigger_data, as: user)

    user_tasks = user.accessible_tasks.enabled.ordered
    stopped = false
    user_tasks.by_listener(trigger).filter_map { |task|
      next if stopped

      ran = nil
      begin
        ran = task.match_run(trigger, trigger_data) && task
      rescue StandardError => e
        unless Rails.env.production?
          load("/Users/zoro/.pryrc")
          source_puts "[#{e.class}] #{e.message}".red
          source_puts focused_backtrace($is_ocs ? e : e.backtrace).join("\n").grey
        end
        nil # Generic rescue
      end
      ran&.tap { stopped = true if ran.stop_propagation? }
    }.tap { |_tasks|
      if !stopped && trigger.to_sym == :command
        trigger_data.deep_symbolize_keys!
        words = trigger_data[:words] || trigger_data.dig(:command, :words)
        ::Jarvis.command(user, words)
      end
    }
  end

  # Used for directly executing code via UI
  def self.async_call(user, code, input_data={}, task: nil, auth: nil)
    # Might need to serialize objects into GID
    ::JilExecuteWorker.perform_async(user.id, code, input_data, task&.id, auth)
  end

  def self.call(user, code, input_data={}, task: nil, auth: nil, broadcast_task: nil)
    new(user, code, input_data, task: task, broadcast_task: broadcast_task).execute_all
  end

  def initialize(user, code, input_data={}, task: nil, auth: nil, broadcast_task: nil)
    # @debug = true && !Rails.env.production?
    load("/Users/zoro/.pryrc") if @debug

    # Need to store auth, but need to remember to pass the id as well
    @user = user
    @task = task
    @broadcast_task = broadcast_task || task
    @ctx = { vars: {}, return_val: nil, state: :running, output: [] }
    @input_data = input_data || {}
    @execution = ::Execution.create(
      user: user, code: code, ctx: @ctx, task: task,
      input_data: TriggerData.serialize(input_data)
    )
    ::Execution.order(started_at: :desc).where(user: user, task: task).offset(5).compact_all
    @lines = ::Jil::Parser.from_code(code)
  end

  def result
    @ctx[:return_val]
  end

  def store_progress(attrs={})
    @execution.update(attrs.merge(ctx: @ctx.except(:vars)))
  end

  def broadcast!
    data = {
      line:      @ctx[:line],
      error:     @ctx[:error] || [],
      output:    @ctx[:output] || [],
      state:     @ctx[:state],
      result:    @ctx[:return_val],
      timestamp: @execution&.last_completion_time || "Waiting...",
    }
    ::TasksChannel.send_to(@user, @execution&.task&.uuid || :new, data)
  end

  def execute_all
    Time.use_zone(@user.timezone) {
      @execution.task&.update(last_trigger_at: Time.current)
      broadcast!
      @ctx[:time_start] = Time.current
      state = :started
      begin
        execute_block(@lines)
        state = :success
      # rescue ::Jil::ExecutionError => e
      #   @ctx[:error] = e.message
      #   state = :failed
      rescue StandardError => e
        @ctx[:error] = "[#{@ctx[:line]}] [#{e.class}] #{e.message}"
        @ctx[:error_line] = e.backtrace.find { |l| l.include?("/app/") }
        state = :failed
      ensure
        @ctx[:state] = :complete
        @ctx[:time_complete] = Time.current
        store_progress(finished_at: @ctx[:time_complete], status: state)
      end
      broadcast!
      self
    }
  end

  def execute_block(lines, current_ctx={})
    current_ctx[:break] = false
    current_ctx[:next] = false

    last_line_val = nil
    Array.wrap(lines).each do |line|
      break unless @ctx[:state] == :running
      next if current_ctx[:break] || current_ctx[:next]
      next if line.commented?

      execute_line(line, current_ctx).tap { |line_val|
        # TODO: We don't need to break these down into hash - just keep the object references in the hash instead
        @ctx[:vars][line.varname.to_sym] = line_val
        last_line_val = line_val[:value]
        if @debug
          str = "#{line.varname} = #{line.objname}.#{line.methodname}(#{line.args.join(", ")})::#{line.cast}"
          source_puts "\e[37m#{str} → #{line_val[:value].inspect}"
        end
      }
    end
    last_line_val
  end

  def execute_line(line, current_ctx={})
    @ctx[:line] = line.varname
    broadcast!
    klass = (
      if line.objname.match?(/^[A-Z]/) # upcase for class or downcase for instance
        klass_from_obj(line.objname)
      else
        raise ::Jil::ExecutionError, "Variable not found: [#{line.objname}]" unless @ctx&.dig(:vars)&.key?(line.objname.to_sym)

        klass_from_obj(@ctx.dig(:vars, line.objname.to_sym))
      end
    )
    obj = klass.new(self, current_ctx || @ctx)

    {
      class: line.cast,
      value: cast(obj.base_execute(line), line.cast, current_ctx),
    }.tap { |line_val|
      if line.shown?
        @ctx[:output] << "[#{line.varname}][#{line_val[:class]}]#{::Jil::Methods::String.new(self, @ctx).cast(line_val[:value]).gsub(
          /^"|"$/, ""
        )}"
      end
    }
  end

  def enumerate_hash(hash, method)
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    hash.each_with_index.send(method) { |(key, val), idx|
      if idx > 1000
        # This should be able to be increased on some functions.
        raise ::Jil::ExecutionError, "Too many Hash iterations!"
      end
      break unless @ctx[:state] == :running
      break unless lctx[:state] == :running
      break if lctx[:break]

      lctx[:key] = key
      lctx[:value] = val
      lctx[:index] = idx

      yield(lctx)
    }
  end

  def enumerate_array(array, method)
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    array.each_with_index.send(method) { |val, idx|
      if idx > 1000
        # This should be able to be increased on some functions.
        raise ::Jil::ExecutionError, "Too many Array iterations!"
      end
      break unless @ctx[:state] == :running
      break unless lctx[:state] == :running
      break if lctx[:break]

      lctx[:value] = val
      lctx[:index] = idx

      yield(lctx)
    }
  end

  def enumerate_loop
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    idx = -1
    last_val = nil
    loop do
      idx += 1
      if idx > 1000
        # This should be able to be increased on some functions.
        raise ::Jil::ExecutionError, "Too many Array iterations!"
      end
      # source_puts "#{idx} → #{lctx}" if @debug
      break unless @ctx[:state] == :running
      break unless lctx[:state] == :running
      break if lctx[:break]

      lctx[:value] = idx
      lctx[:index] = idx

      last_val = yield(lctx)
    end
    last_val
  end

  def cast(value, type=nil, current_ctx={})
    case type
    when nil then magic_cast(value)
    when :Any, :Global then value
    when :None then nil
    when :ScheduleData, :ContactData, :ActionEventData, :MonitorData, :PushNotification, :PromptQuestion
      cast(value, :Hash)
    else klass_from_obj(type).new(self, current_ctx || @ctx).cast(value)
    end
  end

  def klass_from_obj(obj)
    klass_name = obj.to_sym if obj.is_a?(::Symbol) || obj.is_a?(::String)
    klass_name = obj[:class] if obj.is_a?(::Hash)
    klass_name = (
      case klass_name || obj.cast.to_sym
      # when :Hash then ::Hash # dig into the hash for special keys
      when :Object then :Global
      when :Schedule, :ScheduleData then :Schedule
      when :Contact, :ContactData then :Contact
      when :ActionEvent, :ActionEventData then :ActionEvent
      when :Monitor, :MonitorData then :Monitor
      when :PushNotification, :PushNotificationData then :PushNotification
      when :Prompt, :PromptQuestion then :Prompt
      when :Hash, :Keyval then :Hash
      when :String, :Text then :String
      else
        klass_name || obj.class.to_sym
      end
    )
    "::Jil::Methods::#{klass_name}".constantize
  rescue NameError
    raise ::Jil::ExecutionError, "Class does not exist: `#{klass_name}`"
  end

  def magic_cast(value)
    return value unless value.is_a?(::String)

    YAML.safe_load(value, [::Symbol], aliases: true)
  rescue StandardError
    value
  end
end
