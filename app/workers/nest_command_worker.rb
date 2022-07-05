class NestCommandWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(settings)
    NestCommand.command(settings)
  end
end
