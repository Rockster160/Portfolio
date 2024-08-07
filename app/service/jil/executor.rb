class Jil::Executor
  attr_accessor :user, :ctx, :lines

  def self.call(user, code, input_data={})
    new(user, code, input_data).execute_all
  end

  def initialize(user, code, input_data={})
    @user = user
    @ctx = { vars: {}, input_data: input_data, return_val: nil, state: :running, output: [] }
    @lines = ::Jil::Parser.from_code(code)
  end

  def execute_all
    @ctx[:time_start] = Time.current
    begin
      execute_block(@lines)
    # rescue ::Jil::ExecutionError => e
    #   @ctx[:error] = e.message
    rescue => e
      @ctx[:error] = "[#{e.class}] #{e.message}"
      @ctx[:error_line] = e.backtrace.find { |l| l.include?("/app/") }
    end
    @ctx[:state] = :complete
    @ctx[:time_complete] = Time.current
    self
  end

  def execute_block(lines, current_ctx={})
    current_ctx[:break] = false
    current_ctx[:next] = false

    last_line_val = nil
    Array.wrap(lines).each do |line|
      break unless @ctx[:state] == :running
      next if current_ctx[:break] || current_ctx[:next]
      next if line.commented

      execute_line(line, current_ctx).tap { |line_val|
        @ctx[:vars][line.varname.to_sym] = line_val
        last_line_val = line_val[:value]
        # str = "#{line.varname} = #{line.objname}.#{line.methodname}(#{line.args.join(", ")})::#{line.cast}"
        # load("/Users/rocco/.pryrc"); source_puts "\e[37m#{str} → #{line_val[:value].inspect}"
      }
    end
    last_line_val
  end

  def execute_line(line, current_ctx={})
    @ctx[:line] = line.varname
    klass = (
      if line.objname.match?(/^[A-Z]/) # upcase for class or downcase for instance
        klass_from_obj(line.objname)
      else
        unless @ctx&.dig(:vars)&.key?(line.objname.to_sym)
          raise ::Jil::ExecutionError, "Unfound line `#{line.objname.to_sym}`"
        end
        klass_from_obj(@ctx.dig(:vars, line.objname.to_sym))
      end
    )
    obj = klass.new(self, current_ctx || @ctx)

    {
      class: line.cast,
      value: cast(obj.execute(line), line.cast, current_ctx),
    }
  end

  def enumerate_hash(hash, method, &block)
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    hash.each_with_index.send(method) do |(key, val), idx|
      break unless @ctx[:state] == :running
      break unless lctx[:state] == :running
      next (lctx[:next] = false) if lctx[:break] || lctx[:next]

      lctx[:key] = key
      lctx[:value] = val
      lctx[:index] = idx

      yield(lctx)
    end
  end

  def enumerate_array(array, method, &block)
    lctx = { break: false, next: false, state: :running, line: @ctx[:line] }
    array.each_with_index.send(method) do |val, idx|
      break unless @ctx[:state] == :running
      break unless lctx[:state] == :running
      next (lctx[:next] = false) if lctx[:break] || lctx[:next]

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
      # load("/Users/rocco/.pryrc"); source_puts "#{idx} → #{lctx}"
      break unless @ctx[:state] == :running
      break unless lctx[:state] == :running
      break if lctx[:break]

      lctx[:value] = idx
      lctx[:index] = idx

      last_val = yield(lctx)
    end
    last_val
  end

  def cast(value, type, current_ctx={})
    case type
    when :Any, :Global then value
    when :None then nil
    else klass_from_obj(type).new(self, current_ctx || @ctx).cast(value)
    end
  end

  def klass_from_obj(obj)
    # ::ActiveModel::Type::Boolean.new.cast()
    # [ ] Global
    # [ ] Keyval
    # [ ] Text
    # [ ] String
    # [ ] Numeric
    # [ ] Boolean
    # [ ] Duration
    # [ ] Date
    # [ ] Hash
    # [ ] Array
    # [ ] List
    # [ ] ListItem
    # [ ] ActionEvent
    # [ ] Prompt
    # [ ] PromptQuestion
    # [ ] Task
    # [ ] Email
    klass_name = obj.to_sym if obj.is_a?(::Symbol) || obj.is_a?(::String)
    klass_name = obj[:class] if obj.is_a?(::Hash)
    klass_name = (
      case klass_name || obj.cast.to_sym
      # when :Hash then ::Hash # dig into the hash for special keys
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
end
