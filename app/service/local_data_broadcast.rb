class LocalDataBroadcast
  include ActionView::Helpers::DateHelper

  def self.call(data=nil)
    new.call(data)
  end

  def call(data=nil)
    return if Rails.env.development?

    data ||= JSON.parse(File.read("local_data.json")) if File.exists?("local_data.json")
    data ||= {}
    @data = data.deep_symbolize_keys
    @user = User.me

    update_contacts if @data.key?(:contacts)

    if @data.key?(:notes) && @data.dig(:notes, :timestamp) != DataStorage[:notes_timestamp]
      items_hash = @data.dig(:notes, :items)&.map do |item_name|
        { name: item_name }
      end || []
      @user.default_list.add_items(items_hash)
      DataStorage[:notes_timestamp] = @data.dig(:notes, :timestamp)
    end

    ActionCable.server.broadcast(:local_data_channel, enriched_data)

    CalendarEventsWorker.perform_async if @data.key?(:calendar)
    enriched_data
  end

  private

  def enriched_data
    @enriched_data ||= @data.tap do |data|
      data[:calendar] = enrich_calendar(data[:calendar]) if data.key?(:calendar)
      data[:reminders] = enrich_reminders(data[:reminders]) if data.key?(:reminders)
    end
  end

  def update_contacts
    return if Rails.env.development?

    @data[:contacts].each do |contact_data|
      next if contact_data[:phones].blank? && contact_data[:addresses].blank?

      contact = @user.contacts.find_or_initialize_by(apple_contact_id: contact_data[:id])
      contact.update(raw: contact_data)
      contact.resync
    end
  end

  def enrich_calendar(calendar_lines)
    today_str = Time.current.in_time_zone("Mountain Time (US & Canada)").strftime("%b %-d, %Y:")
    calendar_data = LocalDataCalendarParser.call

    grey = "#42464A"
    yellow = "#CBCB4D"
    lblue =  "#3D94F6"
    magenta = "#B55088"
    calendar_colors = {
      "rocco11nicholls@gmail.com"   => lblue,
      "rocco.nicholls@workwave.com" => "#FF9500",
      "Rae Sched"                   => "#6FFB62",
    }

    calendar_data.map { |date_str, events|
      lines = [date_str, "[hr]"]
      events.sort_by { |evt| evt[:start_time] || Time.current.beginning_of_day }.each do |event|
        if event[:time_str].present?
          name = event[:name] || event[:uid]
          color = calendar_colors[event[:calendar]]
          name = "[color #{color}]#{name}[/color]" if color.present?
          lines.push("• #{name}")
          lines.push("    [color #{yellow}]#{event[:time_str]}[/color]")
        else
          lines.push("• [color #{magenta}]#{event[:name] || event[:uid]}[/color]")
        end
        next if event[:location].blank?
        next if event[:location].include?("zoom.us")
        next if event[:location].include?("meet.google")
        next if event[:location].match?(/webinar/i) # GoToWebinar

        lines.push("    [color #{grey}]#{event[:location].strip}[/color]")
      end
      lines.push("") # Empty line between days
    }.flatten
  end

  def enrich_reminders(reminder_data)
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    (reminder_data || []).map do |reminder|
      next reminder[:name] if reminder[:due].blank?

      time = Time.parse(reminder[:due]).in_time_zone("Mountain Time (US & Canada)")
      time_words = distance_of_time_in_words(time, now)
      future = time > now
      if time == now.beginning_of_day
        future = true
        time_words = nil unless time + 1.day < now
      end
      direction = future ? "from now" : "ago"
      next if time > now.end_of_day

      time_color = future ? :grey : "#807A40"
      time_words = "[color #{time_color}]#{time_words} #{direction}[/color]" unless time_words.nil?
      name = future ? reminder[:name] : "[color pink]#{reminder[:name]}[/color]"
      "#{name} #{time_words}"
    rescue StandardError => e
      reminder&.dig(:name) || "FAIL(#{reminder.inspect})"
    end.compact
  end
end
