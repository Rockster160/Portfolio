class FunctionWorker
  include Sidekiq::Worker

  def perform(func_id, *args)
    RunFunction.run(func_id, args)
  end
end
