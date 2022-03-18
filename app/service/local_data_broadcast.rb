class LocalDataBroadcast
  include ActionView::Helpers::DateHelper

  def self.call(data=nil)
    new.call(data)
  end

  def call(data=nil)
    data ||= JSON.parse(File.read("local_data.json"))
    data.deep_symbolize_keys!

    ActionCable.server.broadcast "local_data_channel", encriched_data(data)
  end

  private

  def encriched_data(to_enrich)
    to_enrich.tap do |data|
      data[:reminders] = enrich_reminders(data[:reminders]) if data.key?(:reminders)
    end
  end

  def enrich_reminders(reminder_data)
    now = Time.current
    reminder_data.map do |reminder|
      next reminder[:name] if reminder[:due].blank?

      time = Time.parse(reminder[:due]).in_time_zone("Mountain Time (US & Canada)")
      time_words = distance_of_time_in_words(time, now)
      direction = time > now ? "from now" : "ago"
      "#{reminder[:name]} [color grey]#{time_words} #{direction}[/color]"
    rescue StandardError => e
      reminder&.dig(:name) || "FAIL(#{reminder.inspect})"
    end
  end
end
