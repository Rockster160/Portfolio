class Jil::Executor
  attr_accessor :user, :ctx, :lines

  def self.async_trigger(user, trigger, trigger_data={}, at: nil)
    user_ids = (
      case user
      when ::User then [user.id]
      when ::ActiveRecord::Relation then user.ids
      else ::Array.wrap(user)
      end
    )

    begin
      trigger_data = ::JSON.parse(trigger_data) if trigger_data.is_a?(::String)
    rescue ::JSON::ParserError
      trigger_data = {}
    end

    if at.blank?
      ::JilTriggerWorker.perform_async(user_ids, trigger, trigger_data)
    else
      ::JilTriggerWorker.perform_at(at, user_ids, trigger, trigger_data)
    end
  end

  def self.trigger(user, trigger, trigger_data={})
    # load("/Users/rocco/.pryrc"); source_puts "trigger:#{trigger} #{pretty_hash(trigger_data)}"
    user_ids = (
      case user
      when ::User then [user.id]
      when ::ActiveRecord::Relation then user.ids
      else ::Array.wrap(user)
      end
    )

    begin
      trigger_data = ::JSON.parse(trigger_data) if trigger_data.is_a?(::String)
    rescue ::JSON::ParserError
      trigger_data = { data: trigger_data }
    end

    ::Jarvis.log("\e[35m[#{trigger}] \e[0m" + PrettyLogger.truncate(PrettyLogger.pretty_message({ trigger => trigger_data }), 1000))

    user_tasks = ::JilTask.enabled.ordered.where(user_id: user_ids).distinct
    stopped = false
    user_tasks.by_listener(trigger).filter_map do |task|
      next if stopped
      ran = nil
      begin
        ran = task.match_run(trigger, trigger_data) && task
      rescue => e
        unless Rails.env.production?
          load("/Users/rocco/.pryrc"); source_puts "[#{e.class}] #{e.message}"
        end
        nil # Generic rescue
      end
      ran&.tap { stopped = true if ran.stop_propagation? }
    end
  end

  def self.async_call(user, code, input_data={}, task: nil)
    ::JilExecuteWorker.perform_async(user.id, code, input_data, task&.id)
  end

  def self.call(user, code, input_data={}, task: nil)
    new(user, code, input_data, task: task).execute_all
  end

  def initialize(user, code, input_data={}, task: nil)
    # @debug = true && !Rails.env.production?
    load("/Users/rocco/.pryrc") if @debug

    @user = user
    @ctx = { vars: {}, input_data: input_data, return_val: nil, state: :running, output: [] }
    @execution = ::JilExecution.create(user: user, code: code, ctx: @ctx, jil_task: task)
    ::JilExecution.order(started_at: :desc).where(user: user, jil_task: task).offset(5).destroy_all
    @lines = ::Jil::Parser.from_code(code)
  end

  def result
    @ctx[:return_val]
  end

  def store_progress(attrs={})
    @execution.update(attrs.merge(ctx: @ctx))
  end

  def broadcast!
    data = {
      line: @ctx[:line],
      error: @ctx[:error] || [],
      output: @ctx[:output] || [],
      state: @ctx[:state],
      result: @ctx[:return_val],
      timestamp: @execution&.last_completion_time || "Waiting...",
    }
    ::JilTasksChannel.send_to(@user, @execution&.jil_task&.uuid || :new, data)
  end

  def execute_all
    Time.use_zone(@user.timezone) {
      @execution.jil_task&.update(last_trigger_at: Time.current)
      broadcast!
      @ctx[:time_start] = Time.current
      state = :started
      begin
        execute_block(@lines)
        state = :success
      # rescue ::Jil::ExecutionError => e
      #   @ctx[:error] = e.message
      #   state = :failed
      rescue => e
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
        unless @ctx&.dig(:vars)&.key?(line.objname.to_sym)
          raise ::Jil::ExecutionError, "Variable not found"
        end
        klass_from_obj(@ctx.dig(:vars, line.objname.to_sym))
      end
    )
    obj = klass.new(self, current_ctx || @ctx)

    {
      class: line.cast,
      value: cast(obj.base_execute(line), line.cast, current_ctx),
    }.tap { |line_val|
      if line.shown?
        @ctx[:output] << "[#{line.varname}][#{line_val[:class]}]#{::Jil::Methods::String.new(self, @ctx).cast(line_val[:value]).gsub(/^"|"$/, "")}"
      end
    }
  end

  def enumerate_hash(hash, method, &block)
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    hash.each_with_index.send(method) do |(key, val), idx|
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
    end
  end

  def enumerate_array(array, method, &block)
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    array.each_with_index.send(method) do |val, idx|
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
    end
  end

  def enumerate_loop(&block)
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
      when :Contact, :ContactData then :Contact
      when :ActionEvent, :ActionEventData then :ActionEvent
      when :Monitor, :MonitorData then :Monitor
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
  rescue
    value
  end
end
