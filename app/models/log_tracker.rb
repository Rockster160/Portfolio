# == Schema Information
#
# Table name: log_trackers
#
#  id          :integer          not null, primary key
#  user_agent  :string
#  ip_address  :string
#  http_method :string
#  url         :string
#  params      :string
#  user_id     :integer
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

class LogTracker < ApplicationRecord
  belongs_to :user, optional: true

  after_create_commit :broadcast_creation

  scope :by_fuzzy_url, ->(url) { where("url ILIKE '%#{url}%'") }
  scope :by_ip, ->(ip) { where(ip_address: ip) }

  def self.uniq_ips
    pluck(:ip_address).uniq
  end

  def params_json
    JSON.parse(params.gsub("=>", ":"))
  end

  private

  def broadcast_creation
    rendered_message = LogTrackersController.render partial: 'log_trackers/logger_row', locals: { logger: self }
    ActionCable.server.broadcast "logger_channel", message: rendered_message
  end

end
