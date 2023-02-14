class Jarvis::Execute::Input < Jarvis::Execute::Executor
  def method_missing(method, *method_args, &block)
    input_data = jil.data.dig(:input_vars)&.better
    super(method, *method_args, &block) unless input_data&.key?(method)

    input_data[method]
  end
end
