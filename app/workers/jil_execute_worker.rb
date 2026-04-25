class JilExecuteWorker
  include Sidekiq::Worker

  # Should only be called independently, through the UI when clicking "Run"
  def perform(user_id, code, input_data, task_id=nil, auth=nil, auth_id=nil, trigger_scope=nil)
    user = ::User.find(user_id)
    task = task_id ? ::Task.find(task_id) : nil

    ::Jil::Executor.call(
      user, code, input_data,
      task: task, auth: auth, auth_id: auth_id, trigger_scope: trigger_scope
    )
  end
end
