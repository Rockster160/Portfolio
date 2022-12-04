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
end
