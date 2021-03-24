class RunFunction
  def self.run(function_id, args={})
    new.run(function_id, args)
  end

  def run(function_id, args={})
    @function = Function.find(function_id)
    @args = @function.split_args.merge(args || {})
    @failure = false

    res = run_code(@function.proposed_code)
    finish_command(res)
  rescue Exception => e # Yes, rescue full Exception so that we can catch typos in evals as well
    @failure = true
    finish_command(results_from_exception(e))
  end

  def run_code(code)
    @function.update(deploy_begin_at: Time.current)
    puts "Command(#{@function.id}) running." if Rails.env.development?

    code = "#{bring_function}\narg = HashWithIndifferentAccess.new(#{@args.try(:to_json)})\n\n#{code}"
    puts "\e[31m#{code}\e[0m" if Rails.env.development?

    begin
      $stdout = StringIO.new
      result = eval(code) # Security/Eval - Eval is scary, but in this case it's exactly what we need.
    rescue Exception => e # Yes, rescue full Exception so that we can catch typos in evals as well
      @failure = true

      result = results_from_exception(e)
    ensure
      output = $stdout.try(:string)

      $stdout = STDOUT
    end

    [output, result].map(&:presence).compact.join("\n")
  end

  def bring_function
    "def bring(*func_names); func_names.map { |f| Function.lookup(f).proposed_code }.join(\"\n\"); end"
  end

  def results_from_exception(exc)
    "#{exc.class}: #{exc.try(:message) || exc.try(:body) || exc.to_s}\n\n#{gather_exception_info(exc)}"
  end

  def gather_exception_info(exception)
    error_info = []
    backtrace = full_trace_from_exception(exception)

    eval_trace = backtrace.select { |row| row.include?("(eval)") }.presence || []
    eval_trace = eval_trace.map do |row|
      eval_row_number = row[/\(eval\)\:\d+/].to_s[7..-1]
      next if eval_row_number.blank?

      error_line = @function.proposed_code.split("\n")[eval_row_number.to_i - 1]
      "#{eval_row_number}: #{error_line}" if error_line.present?
    end.compact
    error_info += [">> Eval Trace"] + eval_trace + ["\n"] if eval_trace.any?

    app_trace = backtrace.select { |row| row.include?("/app/") }.presence || []
    error_info += [">> App Trace"] + app_trace + ["\n"] if app_trace.any?

    error_info.join("\n")
  end

  def full_trace_from_exception(exception)
    trace = exception.try(:backtrace).presence
    return trace if trace.present?

    trace = caller.dup
    trace
  end

  def output_text(res)
    return res if res.is_a?(String)
    return res.inspect if res.respond_to?(:inspect)

    res.try(:to_s)
  rescue NoMethodError => e
    "Failed to cast: #{results_from_exception(e)}"
  end

  def finish_command(res)
    @function.update_columns(deploy_finish_at: Time.current)

    puts "\e[32m#{output_text(res)}\e[0m"
    output_text(res)
  rescue Exception => e # rubocop:disable Lint/RescueException - Yes, rescue full Exception so that we can catch typos in evals as well
    Rails.logger.fatal("[#{e.class}](fn:#{@function.id}) #{e.try(:message) || e}")
    # ::SnitchReporting.error(
    #   class:            e.class,
    #   message:          e.try(:message) || e,
    #   command_proposal: {
    #     id:   @function.id,
    #     desc: @function.description
    #   }
    # )
  end
end
