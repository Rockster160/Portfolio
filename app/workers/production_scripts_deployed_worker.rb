# After a deploy (Sidekiq's startup hook, once the new app is up): runs every
# approved ProductionScript whose commit that deploy brought in, and counts the
# ones it brought in that are still waiting on approval.
class ProductionScriptsDeployedWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform
    ProductionScripts.run_deployed!
    ProductionScripts.refresh_chips!
  end
end
