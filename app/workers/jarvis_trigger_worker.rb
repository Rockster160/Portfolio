class JarvisTriggerWorker
  include Sidekiq::Worker

  def perform(action) #, data
    Jarvis.execute_trigger(action) #, data
  end
end
