class AppWidgetReloadWorker
  include Sidekiq::Worker

  sidekiq_options retry: 1, queue: :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    AppPush.reload_widgets(user) if user
  end
end
