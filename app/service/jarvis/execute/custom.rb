class Jarvis::Execute::Custom < Jarvis::Execute::Executor
  def method_missing(method, *method_args, &block)
    run_task = user.jarvis_tasks.find_by(name: method)
    super(method, *method_args, &block) if run_task.blank?

    task_input_data = run_task.inputs.to_h
    data = run_task.inputs.map(&:first).zip(evalargs).map { |k, v|
      type = task_input_data[k].each { |d| break d[:return] if d.is_a?(Hash) && d.key?(:return) }
      [k, ::Jarvis::Execute::Cast.cast(v, type)]
    }.to_h

    custom_ctx, custom_task, custom_data = ::Jarvis::Execute.call_with_data(
      run_task,
      {
        ctx: { i: jil.ctx[:i] },
        input_vars: data,
      }
    )

    jil.ctx[:i] = run_task.last_ctx[:i]

    custom_error = custom_ctx[:msg].find { |msg| msg.include?("] Failed:") }
    if custom_error
      raise custom_error
    else
      # Add last_result_val to JarvisTask and use that instead.
      v = custom_ctx[:vars].to_a.last[1]
      ::Jarvis::Execute::Cast.cast(v, run_task.output_type)
    end
  end
end
