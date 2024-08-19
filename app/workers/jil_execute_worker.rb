class JilExecuteWorker
  include Sidekiq::Worker

  def perform(user_id, code, input_data, task_id=nil)
    user = ::User.find(user_id)
    task = task_id ? ::JilTask.find(task_id) : nil

    ::Jil::Executor.call(user, code, input_data, task: task)
  end
end
