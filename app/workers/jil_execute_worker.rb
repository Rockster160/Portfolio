class JilExecuteWorker
  include Sidekiq::Worker

  def perform(user_id, code, input_data, task_id=nil, auth=nil)
    user = ::User.find(user_id)
    task = task_id ? ::Task.find(task_id) : nil

    ::Jil::Executor.call(user, code, input_data, task: task, auth: auth)
  end
end
