module AppDevices
  # Device readings the phone app sends as `ios_*` triggers. Each also lands in
  # the store the old Shortcut automations used to feed, so the dashboard, the
  # travel funnel and the Workout events keep working with the app in their
  # place. Every landing is a device preference, on by default.
  #
  # Returns the payload the trigger fires with.
  class DeviceData
    def self.call(**)
      new(**).call
    end

    def initialize(device:, key:, data:, pressed_at:)
      @device = device
      @user = device.user
      @key = key.to_s
      @data = data.to_h.deep_symbolize_keys
      @pressed_at = pressed_at
    end

    def call
      case @key
      when "ios_battery" then battery
      when "ios_location" then location
      when "ios_workout" then workout
      when "ios_contacts" then contacts
      when "ios_share" then share
      end
      @data
    end

    private

    attr_reader :device, :user, :data, :pressed_at

    # The dashboard reads `{ phone: { value:, time: } }` and marks a reading
    # older than 12 hours as stale.
    def battery
      return unless device.preference?(:battery_writes_dashboard)
      return if data[:level].nil?

      slot = data[:device].to_s.strip.downcase.presence || "phone"
      user.caches.dig_set(:battery, slot.parameterize(separator: "_"), {
        value:    data[:level].to_f.round,
        time:     (pressed_at.to_f * 1000).round,
        charging: ActiveModel::Type::Boolean.new.cast(data[:charging]),
        name:     data[:name].presence,
      }.compact)
    end

    def location
      lat = data[:lat]
      lng = data[:lng]
      return if lat.blank? || lng.blank?

      ::LocationCache.set([lat, lng], (pressed_at.to_f * 1000).round) if user.me?

      action = data[:action].to_s
      return unless %w[arrived departed].include?(action)
      return unless device.preference?(:location_feeds_travel)

      ::Jil.trigger(
        user, :trytravel, {
          action:    action,
          lat:       lat.to_f,
          lng:       lng.to_f,
          coord:     [lat.to_f, lng.to_f],
          location:  "#{lat},#{lng}",
          source:    :phone,
          via:       :geofence,
          place:     data[:place].presence,
          timestamp: pressed_at.iso8601,
        }.compact, auth: :trigger, auth_id: user.id
      )
    end

    # A workout logged by hand (through Buddy, a Shortcut or the app) has no
    # Health id, and is the same workout when it was logged while it ran or
    # within this long either side of it.
    WORKOUT_SLACK = 30.minutes

    # The hand-logged Workout this Health workout already is, if any. The
    # nearest one wins, so back-to-back sessions each keep their own, and a log
    # that has taken a Health id is no longer a candidate for another.
    def self.logged_workout(user, started:, ended:)
      ended = [ended, started].max
      events = user.action_events.where(name: "Workout")
      events = events.where(timestamp: (started - WORKOUT_SLACK)..(ended + WORKOUT_SLACK))
      events = events.where("data IS NULL OR NOT (data ? 'workout_uuid')")
      events.min_by { |event|
        outside = [started - event.timestamp, event.timestamp - ended, 0].max
        [outside, (event.timestamp - started).abs]
      }
    end

    # The person's title and numbers stay, and Health fills in what they left
    # out. Duration is the exception: the Watch measured it, where a hand log
    # guessed or typed it in one of several formats (`1:04:35`, `00:83:49`,
    # a lowercase `duration` of `00:00:00`), so Health's replaces them all.
    def self.adopt_workout!(event, health, title:)
      mine = event.data.to_h
      mine = mine.except("Duration", "duration") if health["Duration"]
      event.notes = title if event.notes.blank?
      event.update!(data: mine.merge(health) { |_key, kept, theirs| kept.presence || theirs })
      event
    end

    # Whole minutes, the unit every other Workout log stores.
    def self.workout_minutes(minutes)
      minutes&.to_f&.round
    end

    # The same event a Workout log has always been, so FitnessBroadcast and the
    # charts that read `data.Calories` see it. A workout saved twice (HealthKit
    # re-delivers after a restore) is still one event, and so is one that was
    # already logged by hand.
    def workout
      return unless device.preference?(:health_logs_workout_event)

      workout_id = data[:uuid].to_s.presence
      events = user.action_events.where(name: "Workout")
      return if workout_id && events.exists?(["data->>'workout_uuid' = ?", workout_id])

      started = (Time.zone.parse(data[:started_at].to_s) rescue nil) || pressed_at
      ended = (Time.zone.parse(data[:ended_at].to_s) rescue nil)
      ended ||= started + data[:duration_minutes].to_f.minutes
      # A workout from Health is taken as it is. Calories is always present,
      # 0 when Health measured none, because a Workout without it is one the
      # person gets asked to fill in.
      health = {
        "Type"         => data[:type],
        "Duration"     => self.class.workout_minutes(data[:duration_minutes]),
        "Calories"     => data[:calories].to_f.round,
        "Distance"     => data[:distance_miles]&.to_f&.round(2),
        "AvgHeartRate" => data[:avg_heart_rate]&.to_f&.round,
        "MaxHeartRate" => data[:max_heart_rate]&.to_f&.round,
        "Indoor"       => data[:indoor],
        "Source"       => data[:source],
        "workout_uuid" => workout_id,
      }.compact

      title = data[:name].presence || data[:type].to_s.titleize.presence
      logged = workout_id && self.class.logged_workout(user, started: started, ended: ended)
      if logged
        self.class.adopt_workout!(logged, health, title: title)
        ::ActionEventNotifier.notify(user, logged, :changed, auth: :trigger, auth_id: user.id)
        data[:event_id] = logged.id
        return
      end

      event = ::ActionEvent.create!(
        user:      user,
        name:      "Workout",
        notes:     title,
        timestamp: started,
        data:      health,
      )
      ::ActionEventNotifier.notify(user, event, :added, auth: :trigger, auth_id: user.id)
      ::ActionEventBroadcastWorker.perform_async(event.id)
      data[:event_id] = event.id
    end

    # The phone's address book only ever fires the trigger. A contact is stored
    # only when the person asked for it (the share sheet's "Save as a contact"
    # sends `save: true`).
    def contacts
      contact = data[:contact].to_h
      return if contact.blank? || !ActiveModel::Type::Boolean.new.cast(data[:save])

      upsert_contact(contact)
    end

    # Matched by the phone's own id for the contact when it has one; a place
    # saved from the share sheet has none and is always a new contact.
    def upsert_contact(attrs)
      apple_id = attrs[:id].to_s.presence
      record = apple_id && user.contacts.find_by(apple_contact_id: apple_id)
      record ||= user.contacts.new(apple_contact_id: apple_id)

      phones = Array(attrs[:phones]).map { |phone| phone.is_a?(Hash) ? phone[:value] : phone }
      emails = Array(attrs[:emails]).map { |email| email.is_a?(Hash) ? email[:value] : email }
      birthday = birthday_parts(attrs[:birthday])

      record.assign_attributes({
        name:        attrs[:name].presence || record.name,
        last_name:   attrs[:last_name].presence,
        nickname:    attrs[:nickname].presence,
        phone:       phones.first&.gsub(/[^\d]/, "")&.last(10).presence,
        email:       emails.first.presence,
        birth_day:   birthday[:day],
        birth_month: birthday[:month],
        birth_year:  birthday[:year],
      }.compact)
      record.raw = attrs.except(:addresses).merge(addresses: attrs[:addresses]).deep_stringify_keys
      record.save!

      addresses(record, attrs)
      data[:contact_id] = record.id
    end

    # The phone sends `{day:, month:, year:}` with no year when the card has none;
    # a plain date string works too. 1604 is the year Contacts uses for "no year".
    def birthday_parts(raw)
      if raw.is_a?(Hash)
        year = raw[:year].to_i
        return { day: raw[:day]&.to_i, month: raw[:month]&.to_i, year: (year if year > 1604) }
      end

      date = (Date.parse(raw.to_s) rescue nil)
      return {} if date.nil?

      { day: date.day, month: date.month, year: (date.year if date.year > 1604) }
    end

    # A street that is already there is left alone; nothing a phone sends removes one.
    def addresses(record, attrs)
      rows = Array(attrs[:addresses])
      if rows.empty? && attrs[:street].present?
        rows = [{ street: attrs[:street], lat: attrs[:lat], lng: attrs[:lng] }]
      end
      rows.each { |row|
        row = { street: row } unless row.is_a?(Hash)
        street = row[:street].to_s.squish.presence
        next if street.nil?

        address = record.addresses.find_or_initialize_by(street: street)
        address.user = user
        address.label ||= row[:label].presence
        address.lat = row[:lat].to_f if row[:lat].present?
        address.lng = row[:lng].to_f if row[:lng].present?
        address.primary = true if record.addresses.where.not(id: address.id).none?
        address.save!
      }
    end

    # Signed ids from /api/ios/uploads become urls a task can fetch.
    def share
      # The app uploads a photo first and sends its signed id; either key works.
      signed_ids = Array(data[:attachments].presence || data[:attachment_signed_ids])
      return if signed_ids.empty?

      data[:attachments] = signed_ids.filter_map { |signed_id|
        blob = ActiveStorage::Blob.find_signed(signed_id.to_s)
        next if blob.nil?

        path = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
        {
          url:          AppPush.absolute(path),
          filename:     blob.filename.to_s,
          content_type: blob.content_type,
          signed_id:    signed_id.to_s,
        }
      }
    end
  end
end
