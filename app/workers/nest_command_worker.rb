class NestCommandWorker
  include Sidekiq::Worker

  sidekiq_options retry: false, lock: :until_executed

  def perform(settings)
    NestCommand.command(settings)
  end
end
