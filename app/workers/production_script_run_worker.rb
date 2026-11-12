# Runs one approved ProductionScript. Never retried: a script that failed part
# way may have done half its work, and only the owner decides whether it goes
# again (by approving it again).
class ProductionScriptRunWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform(script_id)
    script = ProductionScript.find_by(id: script_id)
    ProductionScripts.run!(script) if script
  end
end
