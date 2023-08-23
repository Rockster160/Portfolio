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
      # evt = {}
      # parsed_obj = {}
      # add_event(parsed_obj, evt) # Adds "today"
      # prev_line = nil
      # raw_calendar_lines.each_with_object(parsed_obj) do |cal_line, parsed_data|
      #   if cal_line.match?(/\w{3} \d{1,2}, \d{4}:/i)
      #     @current_day = Time.zone.parse(cal_line)
      #     next
      #   end
      #
      #   case cal_line
      #   when /\d{1,2}:\d{2} (A|P)M/i
      #     evt[:time_str] = cal_line.sub(/\s+/, "")
      #     start_time_str, end_time_str = cal_line.split(" - ")
      #
      #     if start_time_str.present?
      #       start_hour, start_min = start_time_str.split(":")
      #       start_hour = start_hour.to_i + 12 if start_time_str.match(/PM/) && start_hour.to_i < 12
      #       evt[:start_time] = @current_day.change(hour: start_hour.to_i, min: start_min.to_i)
      #     end
      #
      #     if end_time_str.present?
      #       end_hour, end_min = end_time_str.split(":")
      #       end_hour = end_hour.to_i + 12 if end_time_str.match(/PM/) && end_hour.to_i < 12
      #       evt[:end_time] = @current_day.change(hour: end_hour.to_i, min: end_min.to_i)
      #     end
      #     puts "\e[33m[LOGIT] | prev_line = :timestamp (#{cal_line})}\e[0m"
      #     prev_line = :timestamp
      #   when /location:/i
      #     evt[:location] = cal_line.sub(/\s*location: /i, "")
      #     puts "\e[33m[LOGIT] | prev_line = :location (#{cal_line})}\e[0m"
      #     prev_line = :location
      #   when /notes:/i
      #     evt[:notes] = cal_line.sub(/\s*notes: /i, "")
      #     puts "\e[33m[LOGIT] | prev_line = :notes (#{cal_line})}\e[0m"
      #     prev_line = :notes
      #   when /uid:/i
      #     evt[:uid] = cal_line.sub(/\s*uid: /i, "")
      #     puts "\e[33m[LOGIT] | prev_line = :uid (#{cal_line})}\e[0m"
      #     prev_line = :uid
      #   when /^\-+$/, /^$/, /^•/
      #     add_event(parsed_data, evt) # Add the PREVIOUS events stored data since name is the first
      #     cal_name_regex = / \(([^\)]*?)\)$/
      #     evt[:calendar_name] = cal_line[cal_name_regex].to_s[2..-2]
      #     evt[:name] = cal_line.sub(cal_name_regex, "").sub(/•\s*/, "").sub(/ ?\([^\)]*?\)/, "")
      #     evt = { name: evt[:name] }
      #     puts "\e[33m[LOGIT] | prev_line = :event (#{cal_line})}\e[0m"
      #     prev_line = :event
      #   else
      #     if prev_line == :location
      #       evt[:location] += " " + cal_line.sub(/\s*/i, "")
      #     elsif prev_line == :notes
      #       evt[:notes] += "\n" + cal_line.sub(/\s*/i, "")
      #       next # Do not reset the prev_line
      #     else
      #       evt[:unknown] ||= []
      #       evt[:unknown].push(cal_line)
      #     end
      #     prev_line = nil
      #   end
      # end
    end
  end

  private

  def parse_time(day, time)
    time.split(":").then { |h, m|
      _, h, m, mer = time.match(/(\d+):?(\d+)? ?((?:A|P)M)?/i)&.to_a
      pm = mer.upcase == "PM"
      day.change(hour: h.to_i + (pm ? 12 : 0), min: m.to_i)
    }
  end

  # def add_event(parsed_data, evt)
  #   today_str = @current_day.strftime("%b %-d, %Y:")
  #   parsed_data[today_str] ||= []
  #   return if evt[:uid].blank?
  #   return if parsed_data[today_str].any? { |other_evt| other_evt[:uid] == evt[:uid] }
  #
  #   parsed_data[today_str].push(evt)
  # end
end
