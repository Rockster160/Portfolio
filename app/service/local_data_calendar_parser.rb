class LocalDataCalendarParser
  include ActionView::Helpers::DateHelper

  def self.call(raw_calendar_lines=nil)
    new.call(raw_calendar_lines=nil)
  end

  def call(raw_calendar_lines=nil)
    raw_calendar_lines ||= JSON.parse(File.read("local_data.json")).deep_symbolize_keys[:calendar]
    Time.use_zone("Mountain Time (US & Canada)") do
      @current_day = Time.current
      evt = {}
      parsed_obj = {}
      add_event(parsed_obj, evt) # Adds "today"
      raw_calendar_lines.each_with_object(parsed_obj) do |cal_line, parsed_data|
        if cal_line.match?(/\w{3} \d{1,2}, \d{4}:/i)
          @current_day = Time.parse(cal_line)
          next
        end

        if cal_line.starts_with?("•")
          add_event(parsed_data, evt)
          evt = { name: cal_line.sub(/•\s*/, "") }
          next
        end

        case cal_line
        when /\d{1,2}:\d{2} (A|P)M/i
          evt[:time_str] = cal_line.sub(/\s+/, "")
          start_time_str, end_time_str = cal_line.split(" - ")

          if start_time_str.present?
            start_hour, start_min = start_time_str.split(":")
            start_hour = start_hour.to_i + 12 if start_time_str.match(/PM/)
            evt[:start_time] = @current_day.change(hour: start_hour.to_i, min: start_min.to_i)
          end

          if end_time_str.present?
            end_hour, end_min = end_time_str.split(":")
            end_hour = end_hour.to_i + 12 if end_time_str.match(/PM/)
            evt[:end_time] = @current_day.change(hour: end_hour.to_i, min: end_min.to_i)
          end
        when /location:/i
          evt[:location] = cal_line.sub(/\s*location: /i, "")
        when /uid:/i
          evt[:uid] = cal_line.sub(/\s*uid: /i, "")
        when /^\-+$/, /^$/
          # no-op, skip the dash lines and empty spaces
        else
          evt[:unknown] ||= []
          evt[:unknown].push(cal_line)
        end
      end
    end
  end

  private

  def add_event(parsed_data, evt)
    today_str = @current_day.strftime("%b %-d, %Y:")
    parsed_data[today_str] ||= []
    return if evt[:uid].blank?

    parsed_data[today_str].push(evt)
  end
end
