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
#  ip_count    :integer
#  location_id :integer
#

class LogTracker < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :location, optional: true

  after_initialize :set_additional_tracking
  after_create_commit :broadcast_creation

  scope :by_fuzzy_url, ->(url) { where("url ILIKE '%#{url}%'") }
  scope :by_ip, ->(ip) { where(ip_address: ip) }
  scope :not_me, -> { where.not(user_id: 1) }
  scope :not_log_tracker, -> { where.not("url ILIKE 'log_tracker'") }

  def self.uniq_ips
    pluck(:ip_address).uniq
  end

  def params_json
    JSON.parse(params.gsub("=>", ":"))
  end

  def short_location
    return nil unless location.present?
    "#{location.country_code}, #{location.region_code}, #{location.city}"
  end

  private

  def set_additional_tracking
    set_ip_count if ip_count.nil?
    geolocate if location_id.nil?
  end

  def geolocate
    new_location_id = LogTracker.where(ip_address: self.ip_address).where.not(location_id: nil).pluck(:location_id).uniq.first
    self.location_id = new_location_id || Location.create(ip: self.ip_address).id
  end

  def set_ip_count
    now = self.created_at || DateTime.current
    self.ip_count = LogTracker.where.not(id: self.id).where("created_at < ?", now).where(ip_address: self.ip_address).count
  end

  def broadcast_creation
    rendered_message = LogTrackersController.render partial: 'log_trackers/logger_row', locals: { logger: self }
    ActionCable.server.broadcast "logger_channel", message: rendered_message
  end

end
