class FunctionWorker
  include Sidekiq::Worker

  def perform(func_id, *args)
    ::CommandProposal::Services::Runner.command(func_id, User.find(1), args)
  end
end
