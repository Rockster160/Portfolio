class Jarvis::Execute::Executor
  attr_accessor :jil, :task_block

  delegate :eval_block, to: :jil

  def initialize(jil, task_block)
    @jil = jil
    @task_block = task_block
  end

  def args
    task_block[:data]
  end

  def evalargs
    args.map { |t| eval_block(t) }.then { |arr| arr.length == 1 ? arr.first : arr }
  end

  def user
    @user ||= jil.task.user
  end

  def current_user
    user
  end
end
