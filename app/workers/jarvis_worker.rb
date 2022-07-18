class JarvisWorker
  include Sidekiq::Worker

  def perform(user_id, message)
    Jarvis.command(User.find(user_id), message)
    Jarvis::Schedule.cleanup
  end
end
