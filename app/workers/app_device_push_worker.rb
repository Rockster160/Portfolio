# A silent push telling one phone to do something now: pick up settings changed
# on the site, or run one of its own tasks (a sync, a battery send).
class AppDevicePushWorker
  include Sidekiq::Worker

  sidekiq_options retry: 1, queue: :default

  def perform(device_id, data)
    device = AppDevice.active.find_by(id: device_id)
    return if device&.apns_token.blank?

    AppPush.deliver_to(device, AppPush.background(data.symbolize_keys), push_type: :background)
  end
end
