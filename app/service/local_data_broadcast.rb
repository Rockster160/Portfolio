class LocalDataBroadcast
  include ActionView::Helpers::DateHelper

  CALENDAR_COLORS = {
    grey:     "#42464A",
    yellow:   "#CBCB4D",
    paleblue: "#9FE1E7",
    lblue:    "#3D94F6",
    magenta:  "#B55088",
    pink:     "#EE9BB5",
    green:    "#65DB39",
    pine:     "#3E8948",
    orange:   "#FF9500",
    brown:    "#A2845D",
    red:      "#FF0000",
  }

  def self.call(data=nil)
    new.call(data)
  end

  def call(data=nil)
    data ||= DataStorage[:local_data] || {}
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
      # data[:reminders] = enrich_reminders(data[:reminders]) if data.key?(:reminders)
    end
  end

  def update_contacts
    return if Rails.env.development?

    @data[:contacts].each do |contact_data|
      next if contact_data[:phones].blank? && contact_data[:addresses].blank?

      contact = @user.contacts.find_or_initialize_by(apple_contact_id: contact_data[:id])
      next if contact.raw == contact_data

      contact.update(raw: contact_data)
      contact.resync
    end
  end

  def ignore_list
    [
      "Rich's w/end",
      "Doug Works",
      "rocco.nicholls@workwave.com",
      "rocco@oneclaimsolution.com",
    ]
  end

  def colorize(text, color)
    "[color #{CALENDAR_COLORS[color] || CALENDAR_COLORS[:red]}]#{text}[/color]"
  end

  def enrich_calendar(calendar_lines)
    today_str = Time.current.in_time_zone("Mountain Time (US & Canada)").strftime("%b %-d, %Y:")
    calendar_data = LocalDataCalendarParser.call

    mapped_colors = {
      "rocco11nicholls@gmail.com"   => :lblue,
      "rocco.nicholls@workwave.com" => :orange,
      "rocco@oneclaimsolution.com"  => :pine,
      "Janaya"                      => :pink,
      "Workout"                     => :brown,
    }

    calendar_data.map { |date_str, events|
      lines = [date_str, "[hr]"]
      events.sort_by { |evt| evt[:start_time] || Time.current.beginning_of_day }.each do |event|
        next if event[:name].in?(ignore_list)
        if event[:time_str].present?
          name = event[:name] || event[:uid]
          color = mapped_colors[event[:calendar]]
          name = colorize(name, color) if color.present?
          lines.push("• #{name}")
          lines.push("    #{colorize(event[:time_str], :yellow)}")
        else
          lines.push("• #{colorize(event[:name] || event[:uid], :magenta)}")
        end
        next if event[:location].blank?
        next if event[:location].include?("zoom.us")
        next if event[:location].include?("meet.google")
        next if event[:location].match?(/webinar/i) # GoToWebinar

        lines.push("    #{colorize(event[:location].strip, :grey)}")
      end
      lines.push("") # Empty line between days
    }.flatten
  end

  # def enrich_reminders(reminder_data)
  #   now = Time.current.in_time_zone("Mountain Time (US & Canada)")
  #   (reminder_data || []).map do |reminder|
  #     next reminder[:name] if reminder[:due].blank?
  #
  #     time = Time.parse(reminder[:due]).in_time_zone("Mountain Time (US & Canada)")
  #     time_words = distance_of_time_in_words(time, now)
  #     future = time > now
  #     if time == now.beginning_of_day
  #       future = true
  #       time_words = nil unless time + 1.day < now
  #     end
  #     direction = future ? "from now" : "ago"
  #     next if time > now.end_of_day
  #
  #     time_color = future ? :grey : "#807A40"
  #     time_words = "[color #{time_color}]#{time_words} #{direction}[/color]" unless time_words.nil?
  #     name = future ? reminder[:name] : "[color pink]#{reminder[:name]}[/color]"
  #     "#{name} #{time_words}"
  #   rescue StandardError => e
  #     reminder&.dig(:name) || "FAIL(#{reminder.inspect})"
  #   end.compact
  # end
end
