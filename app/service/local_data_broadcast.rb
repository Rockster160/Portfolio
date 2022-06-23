class LocalDataBroadcast
  include ActionView::Helpers::DateHelper

  def self.call(data=nil)
    new.call(data)
  end

  def call(data=nil)
    data ||= JSON.parse(File.read("local_data.json"))
    data = data.deep_symbolize_keys

    if data.dig(:notes, :timestamp) != DataStorage[:notes_timestamp]
      items_hash = data.dig(:notes, :items).map do |item_name|
        { name: item_name }
      end
      User.find(1).lists.find_by(name: "Todo").add_items(items_hash)
      DataStorage[:notes_timestamp] = data.dig(:notes, :timestamp)
    end

    ActionCable.server.broadcast "local_data_channel", encriched_data(data)
  end

  private

  def encriched_data(to_enrich)
    to_enrich.tap do |data|
      data[:calendar] = enrich_calendar(data[:calendar]) if data.key?(:calendar)
      data[:reminders] = enrich_reminders(data[:reminders]) if data.key?(:reminders)
    end
  end

  def enrich_calendar(calendar_data)
    today_str = Time.current.in_time_zone("Mountain Time (US & Canada)").strftime("%b %-d, %Y:")
    return calendar_data if calendar_data.include?(today_str)

    today_chunk = [
      today_str,
      "------------------------",
      "  No Events left today",
      "",
    ]

    today_chunk + calendar_data
  end

  def enrich_reminders(reminder_data)
    now = Time.current.in_time_zone("Mountain Time (US & Canada)")
    reminder_data.map do |reminder|
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
