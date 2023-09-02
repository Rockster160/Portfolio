class LocalDataCalendarParser
  include ActionView::Helpers::DateHelper

  def self.call(raw_calendar_lines=nil)
    new.call(raw_calendar_lines=nil)
  end

  def call(raw_calendar_lines=nil)
    raw_calendar_lines ||= JSON.parse(File.read("local_data.json")).deep_symbolize_keys[:calendar]

    used_uids = []
    Time.use_zone(User.timezone) do
      # Add the current day always
      cal = { Time.zone.now.strftime("%b %-d, %Y") => [] }
      raw_calendar_lines.each_with_object(cal) do |(day, evts), parsed_cal|
        current_day = Time.zone.parse(day.to_s)
        parsed_cal[day.to_s] ||= []
        evts.each do |evt|
          next if used_uids.include?(evt[:uid])

          used_uids << evt[:uid]
          evt[:name] = evt[:name].sub(/ ?\(.*?\)/, "")
          evt[:time_str] = [evt[:start_time], evt[:end_time]].map(&:presence).compact.join(" - ")
          evt[:start_time] = parse_time(current_day, evt[:start_time]) if evt[:start_time].present?
          evt[:end_time] = parse_time(current_day, evt[:end_time]) if evt[:end_time].present?
          evt[:location] = evt[:location].gsub("\n", " ") if evt[:location].present?
          parsed_cal[day.to_s] << evt
        end
      end
    end
  end

  private

  def parse_time(day, time)
    time.split(":").then { |h, m|
      _, h, m, mer = time.match(/(\d+):?(\d+)? ?((?:A|P)M)?/i)&.to_a
      pm = mer.upcase == "PM" && h.to_i < 12
      day.change(hour: h.to_i + (pm ? 12 : 0), min: m.to_i)
    }
  end
end
