class Jarvis::Execute::Custom < Jarvis::Execute::Executor
  def method_missing(method, *method_args, &block)
    begin
      run_task = user.jarvis_tasks.anyfind(method)
    rescue ActiveRecord::RecordNotFound
      run_task = nil
    end
    super(method, *method_args, &block) if run_task.blank?

    task_input_data = run_task.inputs.to_h
    data = run_task.inputs.map(&:first).zip(Array.wrap(evalargs)).map { |k, v|
      type = task_input_data[k].each { |d| break d[:return] if d.is_a?(Hash) && d.key?(:return) }
      # If there is no `return` this should fail somehow?
      [k, ::Jarvis::Execute::Cast.cast(v, type, jil: jil)]
    }.to_h

    custom_ctx, custom_task, custom_data = ::Jarvis::Execute.call_with_data(
      run_task,
      {
        ctx: { i: jil.ctx[:i] }, # Pass `i` so that we properly error our over 1k tasks
        input_vars: data,
      }
    )

    jil.ctx[:i] = run_task.last_ctx[:i] # Take the `i` back from the other task to continue counting

    custom_error = custom_ctx[:msg].find { |msg| msg.to_s.include?("] Failed:") }
    if custom_error
      raise custom_error
    else
      # Don't use last_result_val - it stores `true` as "t"
      ::Jarvis::Execute::Cast.cast(custom_task.last_ctx[:last_val], run_task.output_type, jil: jil)
    end
  end
end
