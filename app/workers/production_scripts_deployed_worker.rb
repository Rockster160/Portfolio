# After a deploy (Sidekiq's startup hook, once the new app is up): runs every
# approved ProductionScript whose commit that deploy brought in.
class ProductionScriptsDeployedWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform
    ProductionScripts.run_deployed!
  end
end
