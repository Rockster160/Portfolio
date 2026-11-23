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
#  hot_links            :jsonb            not null
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
    open_links_in_app:             true,
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
  HOT_LINK_KINDS = [
    :open,
    :command,
    :buddy,
    :task,
    :routine,
    :trigger,
    :check_in,
    :prompt,
    :list_toggle,
    :url,
  ].freeze
  # iOS shows the first four on the app icon; the rest still reach widgets,
  # Control Center and Shortcuts.
  MAX_HOT_LINKS = 12
  # The app icon's long-press menu draws SF Symbols only, so a hot link's icon
  # is one of these, named for searching.
  HOT_LINK_SYMBOLS = {
    "bolt.fill"                           => "Bolt",
    "star.fill"                           => "Star",
    "heart.fill"                          => "Heart",
    "flag.fill"                           => "Flag",
    "bell.fill"                           => "Bell",
    "bookmark.fill"                       => "Bookmark",
    "tag.fill"                            => "Tag",
    "sparkles"                            => "Sparkles",
    "flame.fill"                          => "Flame",
    "bubble.left.fill"                    => "Message",
    "bubble.left.and.bubble.right.fill"   => "Conversation",
    "text.bubble.fill"                    => "Text bubble",
    "phone.fill"                          => "Phone",
    "envelope.fill"                       => "Mail",
    "paperplane.fill"                     => "Send",
    "mic.fill"                            => "Microphone",
    "questionmark.circle.fill"            => "Question",
    "checkmark.circle.fill"               => "Check",
    "plus.circle.fill"                    => "Plus",
    "list.bullet"                         => "List",
    "checklist"                           => "Checklist",
    "square.and.pencil"                   => "Note",
    "doc.text.fill"                       => "Document",
    "calendar"                            => "Calendar",
    "clock.fill"                          => "Clock",
    "timer"                               => "Timer",
    "alarm.fill"                          => "Alarm",
    "stopwatch.fill"                      => "Stopwatch",
    "hourglass"                           => "Hourglass",
    "house.fill"                          => "House",
    "building.2.fill"                     => "Office",
    "door.left.hand.open"                 => "Door",
    "door.garage.closed"                  => "Garage",
    "lock.fill"                           => "Lock",
    "lock.open.fill"                      => "Unlock",
    "key.fill"                            => "Key",
    "lightbulb.fill"                      => "Light",
    "lamp.desk.fill"                      => "Lamp",
    "fan.fill"                            => "Fan",
    "thermometer.medium"                  => "Thermometer",
    "snowflake"                           => "Snowflake",
    "sun.max.fill"                        => "Sun",
    "moon.fill"                           => "Moon",
    "cloud.rain.fill"                     => "Rain",
    "umbrella.fill"                       => "Umbrella",
    "bed.double.fill"                     => "Bed",
    "sofa.fill"                           => "Sofa",
    "tv.fill"                             => "TV",
    "washer.fill"                         => "Washer",
    "dishwasher.fill"                     => "Dishwasher",
    "trash.fill"                          => "Trash",
    "spigot.fill"                         => "Tap",
    "shower.fill"                         => "Shower",
    "car.fill"                            => "Car",
    "bus.fill"                            => "Bus",
    "bicycle"                             => "Bicycle",
    "airplane"                            => "Airplane",
    "fuelpump.fill"                       => "Fuel",
    "bolt.car.fill"                       => "Car charging",
    "map.fill"                            => "Map",
    "location.fill"                       => "Location",
    "mappin.and.ellipse"                  => "Pin",
    "signpost.right.fill"                 => "Directions",
    "figure.walk"                         => "Walking",
    "figure.run"                          => "Running",
    "figure.strengthtraining.traditional" => "Weights",
    "figure.yoga"                         => "Yoga",
    "dumbbell.fill"                       => "Dumbbell",
    "drop.fill"                           => "Water",
    "cup.and.saucer.fill"                 => "Coffee",
    "mug.fill"                            => "Mug",
    "wineglass.fill"                      => "Wine",
    "fork.knife"                          => "Food",
    "carrot.fill"                         => "Carrot",
    "birthday.cake.fill"                  => "Cake",
    "cart.fill"                           => "Cart",
    "bag.fill"                            => "Bag",
    "creditcard.fill"                     => "Card",
    "dollarsign.circle.fill"              => "Money",
    "gift.fill"                           => "Gift",
    "pills.fill"                          => "Pills",
    "cross.case.fill"                     => "First aid",
    "heart.text.square.fill"              => "Health",
    "bandage.fill"                        => "Bandage",
    "brain.head.profile"                  => "Mind",
    "face.smiling"                        => "Smile",
    "person.fill"                         => "Person",
    "person.2.fill"                       => "People",
    "figure.and.child.holdinghands"       => "Family",
    "dog.fill"                            => "Dog",
    "cat.fill"                            => "Cat",
    "pawprint.fill"                       => "Paw",
    "leaf.fill"                           => "Leaf",
    "tree.fill"                           => "Tree",
    "camera.fill"                         => "Camera",
    "photo.fill"                          => "Photo",
    "music.note"                          => "Music",
    "headphones"                          => "Headphones",
    "speaker.wave.2.fill"                 => "Speaker",
    "play.fill"                           => "Play",
    "gamecontroller.fill"                 => "Game",
    "book.fill"                           => "Book",
    "graduationcap.fill"                  => "School",
    "briefcase.fill"                      => "Work",
    "hammer.fill"                         => "Hammer",
    "wrench.and.screwdriver.fill"         => "Tools",
    "paintbrush.fill"                     => "Paint",
    "scissors"                            => "Scissors",
    "printer.fill"                        => "Printer",
    "desktopcomputer"                     => "Computer",
    "laptopcomputer"                      => "Laptop",
    "iphone"                              => "iPhone",
    "wifi"                                => "Wi-Fi",
    "battery.100"                         => "Battery",
    "power"                               => "Power",
    "gearshape.fill"                      => "Settings",
    "magnifyingglass"                     => "Search",
    "link"                                => "Link",
    "globe"                               => "Globe",
    "chart.bar.fill"                      => "Chart",
    "chart.line.uptrend.xyaxis"           => "Trend",
    "gauge.with.dots.needle.33percent"    => "Gauge",
    "shippingbox.fill"                    => "Package",
    "archivebox.fill"                     => "Archive",
    "tray.full.fill"                      => "Inbox",
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
  def configure!(features: nil, preferences: nil, hot_links: nil)
    attrs = {}
    attrs[:features] = allowed_features(features) unless features.nil?
    attrs[:preferences] = self.preferences.to_h.merge(cast_preferences(preferences)) unless preferences.nil?
    attrs[:hot_links] = clean_hot_links(hot_links) unless hot_links.nil?
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

  def test_push!(kind, user: self.user)
    case kind.to_s
    when "badge"
      AppPush.deliver_to(self, { aps: { badge: 1 } })
    when "silent"
      AppPush.deliver_to(self, AppPush.background(test: true), push_type: :background)
    when "widgets"
      AppPush.reload_widgets(user).first
    when "live_activity"
      # The timer's own broadcast starts the Live Activity, as any other would.
      Buddy::Timers.create!(user: user, seconds: 60, label: "Test timer")
      Apns::Result.new(status: 200, reason: :TimerStarted)
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
      hot_links:            hot_links,
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

  def clean_hot_links(list)
    Array(list).first(MAX_HOT_LINKS).filter_map { |link|
      link = link.to_h.deep_stringify_keys
      action = link["action"].to_h
      next if link["title"].to_s.strip.blank?
      next unless HOT_LINK_KINDS.include?(action["kind"].to_s.to_sym)

      {
        id:       link["id"].presence || SecureRandom.uuid,
        title:    link["title"].to_s.strip,
        subtitle: link["subtitle"].to_s.strip.presence,
        icon:     link["icon"].to_s.strip.presence || "bolt.fill",
        action:   clean_action(action),
      }.compact
    }
  end

  def clean_action(action)
    {
      kind:        action["kind"].to_s,
      value:       action["value"].to_s.strip.presence,
      send_as:     [:buddy, :command].find { |kind| kind.to_s == action["send_as"].to_s }&.to_s,
      prefix:      action["prefix"].to_s.presence,
      placeholder: action["placeholder"].to_s.strip.presence,
      data:        json_data(action["data"]),
      inline:      ActiveModel::Type::Boolean.new.cast(action["inline"]),
    }.compact
  end

  def json_data(raw)
    return raw if raw.is_a?(Hash)
    return if raw.to_s.strip.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    raise ArgumentError, "A hot link's data isn't valid JSON: #{raw.to_s.truncate(40)}"
  end
end
