# == Schema Information
#
# Table name: app_devices
#
#  id                   :bigint           not null, primary key
#  apns_environment     :text
#  apns_token           :text
#  app                  :text             default("buddy"), not null
#  app_version          :text
#  features             :jsonb            not null
#  last_seen_at         :datetime
#  model                :text
#  name                 :text
#  os_version           :text
#  permissions          :jsonb            not null
#  platform             :text
#  preferences          :jsonb            not null
#  push_to_start_tokens :jsonb            not null
#  revoked_at           :datetime
#  sources              :jsonb            not null
#  timezone             :text
#  token_digest         :text             not null
#  widget_push_token    :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  user_id              :bigint           not null
#
class AppDevice < ApplicationRecord
  TOKEN_PREFIX = "bdy_".freeze
  # Where the TestFlight or App Store link is kept once there is one, so it can
  # change on the devices page without a deploy.
  INSTALL_LINK = :buddy_ios_install_url
  FEATURES = AppDevices::Features::KEYS
  PERMISSION_FEATURES = AppDevices::Features::PERMISSION_KEYS
  PERMISSION_STATES = [:granted, :denied, :undetermined].freeze
  # What a device does before anyone changes anything. A feature that needs a
  # permission from iOS starts off and stays off until the phone is allowed it.
  DEFAULT_FEATURES = (FEATURES - PERMISSION_FEATURES).freeze
  DEFAULT_PREFERENCES = {
    push_badges:                   true,
    native_push_replaces_web_push: false,
    open_links_in_app:             false,
    push_channels:                 [:byte, :timers, :agenda, :chores, :whisper, :jarvis],
    live_activities_for_timers:    true,
    live_activities_for_alarms:    true,
    live_activities_push_to_start: true,
    alarms_ring_alarms:            true,
    alarms_ring_timers:            false,
    commands_show_confirmations:   true,
    battery_writes_dashboard:      true,
    location_mode:                 :significant,
    location_visits:               true,
    location_regions:              true,
    location_feeds_travel:         true,
    location_minimum_meters:       150,
    health_logs_workout_event:     true,
    health_daily_totals:           false,
    calendar_days_back:            7,
    calendar_days_ahead:           60,
    calendar_identifiers:          [],
    reminders_include_completed:   false,
    reminder_list_identifiers:     [],
  }.freeze

  belongs_to :user
  has_many :submissions, class_name: "AppDeviceSubmission", dependent: :delete_all
  has_many :live_activities, class_name: "AppLiveActivity", dependent: :delete_all

  scope :active, -> { where(revoked_at: nil) }
  scope :pushable, -> { active.where.not(apns_token: [nil, ""]) }

  # Returns the device and the raw token. Only the digest is stored, so the raw
  # token exists in exactly one place afterwards: the phone's keychain.
  def self.issue!(user, **attrs)
    raw = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    device = create!(user: user, token_digest: digest(raw), features: DEFAULT_FEATURES, **attrs)
    [device, raw]
  end

  def self.install_url = DataStorage[INSTALL_LINK].presence

  def self.install_url=(url)
    url = url.to_s.strip
    raise ArgumentError, "An install link starts with https://" if url.present? && !url.start_with?("https://")

    DataStorage[INSTALL_LINK] = url.presence
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  def self.token?(raw)
    raw.to_s.start_with?(TOKEN_PREFIX)
  end

  def self.authenticate(raw)
    return unless token?(raw)

    active.find_by(token_digest: digest(raw))
  end

  def self.for_push(user, feature=:push)
    pushable.where(user: user).select { |device| device.feature?(feature) }
  end

  def feature?(key)
    Array(features).map(&:to_s).include?(key.to_s)
  end

  # Whether iOS lets this feature run on the phone. Only the permission
  # features ever wait on this.
  def permitted?(key)
    return true unless PERMISSION_FEATURES.include?(key.to_s.to_sym)

    permission(key) == :granted
  end

  def permission(key)
    permissions.to_h[key.to_s].presence&.to_sym || :undetermined
  end

  def preference(key)
    stored = (preferences || {})[key.to_s]
    stored.nil? ? DEFAULT_PREFERENCES[key.to_sym] : stored
  end

  def preference?(key)
    preference(key).present? && preference(key) != "false"
  end

  def all_preferences
    DEFAULT_PREFERENCES.to_h { |key, _| [key, preference(key)] }
  end

  def push_channel?(channel)
    Array(preference(:push_channels)).map(&:to_s).include?(channel.to_s)
  end

  # The device page's form. A permission feature switches on only once the
  # phone has been allowed it, so a form can't turn on what iOS won't run.
  def configure!(features: nil, preferences: nil)
    attrs = {}
    attrs[:features] = allowed_features(features) unless features.nil?
    attrs[:preferences] = self.preferences.to_h.merge(cast_preferences(preferences)) unless preferences.nil?
    update!(attrs)
    nudge!(settings: true)
  end

  # What the phone says about itself: what iOS allows, and which calendars and
  # reminder lists there are to choose from. A feature allowed after a tap on
  # the phone switches on; one iOS no longer allows switches off.
  def report!(permissions: nil, sources: nil, turn_on: nil)
    if permissions
      states = permissions.to_h.to_h { |key, state| [key.to_s, state.to_s] }
      states = states.select { |key, state|
        PERMISSION_FEATURES.include?(key.to_sym) && PERMISSION_STATES.include?(state.to_sym)
      }
      self.permissions = self.permissions.to_h.merge(states)
    end
    self.sources = sources.to_h if sources
    self.features = allowed_features(Array(features) | Array(turn_on).map(&:to_s))
    save!
  end

  # Runs one of the phone's own tasks (a sync, a battery send) from the site.
  def run!(task)
    raise ArgumentError, "Unknown task" unless AppDevices::Features::TASKS.include?(task.to_s.to_sym)

    nudge!(device_task: task.to_s)
  end

  def nudge!(data)
    AppDevicePushWorker.perform_async(id, data.deep_stringify_keys)
  end

  def test_push!(kind)
    case kind.to_s
    when "badge"
      AppPush.deliver_to(self, { aps: { badge: 1 } })
    else
      test = { title: "Buddy", body: "Native push is working.", tag: "test-push" }
      AppPush.deliver_to(self, AppPush.alert_payload(self, test, channel: :jarvis))
    end
  end

  def revoked? = revoked_at.present?

  def revoke!
    update!(revoked_at: Time.current, apns_token: nil, widget_push_token: nil)
  end

  # Throttled so a phone polling widgets doesn't write a row on every request.
  def seen!
    return if last_seen_at.present? && last_seen_at > 1.minute.ago

    update_columns(last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def serialize
    {
      id:                   id,
      app:                  app,
      name:                 name,
      platform:             platform,
      model:                model,
      os_version:           os_version,
      app_version:          app_version,
      timezone:             timezone,
      apns_token:           apns_token,
      apns_environment:     apns_environment,
      push_to_start_tokens: push_to_start_tokens,
      widget_push_token:    widget_push_token,
      features:             features,
      preferences:          all_preferences,
      permissions:          permissions,
      sources:              sources,
      hot_links:            user.hot_links,
      dark_mode:            !!user.dark_mode?,
      last_seen_at:         last_seen_at,
      created_at:           created_at,
    }
  end

  private

  def allowed_features(list)
    keys = Array(list).map(&:to_s) & FEATURES.map(&:to_s)
    keys.select { |key| permitted?(key) }
  end

  def cast_preferences(raw)
    raw.to_h.each_with_object({}) { |(key, value), cast|
      option = AppDevices::Features::OPTIONS[key.to_s.to_sym]
      next if option.nil?

      cast[option.key.to_s] = cast_option(option, value)
    }.compact
  end

  def cast_option(option, value)
    case option.type
    when :boolean
      ActiveModel::Type::Boolean.new.cast(value) || false
    when :select
      option.choices.key?(value.to_s.to_sym) ? value.to_s : nil
    when :number
      value.to_i.clamp(option.minimum, option.maximum)
    when :channels
      Array(value).map(&:to_s) & option.choices.keys.map(&:to_s)
    when :sources
      Array(value).compact_blank.map(&:to_s)
    end
  end
end
