module Shipments
  # Shared delivery date/time text parsing for the carrier parsers
  # (AmazonEmailParser, UpsSmsParser, UspsEmailParser). Extracted so there is a
  # single implementation of the "Arriving <weekday>/<Month day>/between …"
  # and delivery-window logic. Assumes the caller has set Time.zone to the
  # user's timezone (AmazonEmailParser.parse wraps in Time.use_zone).
  module DateParsing
    MONTH_NAMES = Date::MONTHNAMES.compact
    MONTH_REGEX = Regexp.new("\\b(?:#{MONTH_NAMES.flat_map { |m| [m, m.first(3)] }.join("|")})\\b")
    DAY_NAMES = Date::DAYNAMES.compact
    WDAY_REGEX = Regexp.new("\\b(?:#{DAY_NAMES.flat_map { |d| [d, d.first(3)] }.join("|")})\\b")

    # A bare weekday/month-day has no year; roll it forward so a date that has
    # already passed this week/year resolves to the next occurrence.
    def future(date)
      loop { date.past? ? date += 1.week : (break date) }
    end

    def arrival_date_from(text)
      return nil if text.blank?

      # "Delivered today" / "Delivered yesterday" / "Your package was delivered"
      return Time.zone.today if text.match?(/Delivered\s+today|Your package was delivered|Your package has been delivered/i)
      return Time.zone.today - 1.day if text.match?(/Delivered\s+yesterday/i)

      # "Arriving overnight ..." - overnight means by the next morning
      return Time.zone.today + 1.day if text.match?(/Arriving\s+overnight/i)

      # "Arriving today" / "Arriving tomorrow"
      return Time.zone.today if text.match?(/Arriving\s+today/i)
      return Time.zone.today + 1.day if text.match?(/Arriving\s+tomorrow/i)

      # "Arriving <Weekday>" - parse to next occurrence
      if (match = text.match(/Arriving\s+(#{WDAY_REGEX})/))
        return future(Date.parse(match[1]))
      end

      # "Arriving <Month> <day>" / "Estimated to arrive by <Month> <day>" - explicit date
      if (match = text.match(/(?:Arriving|Estimated\s+to\s+arrive)\s+(?:by\s+)?(#{MONTH_REGEX}\s+\d{1,2})/i))
        return future(Date.parse(match[1]))
      end

      # "Arriving between <Month> <day>" - take the lower bound
      if (match = text.match(/Arriving\s+between\s+(#{MONTH_REGEX}\s+\d{1,2})/))
        return future(Date.parse(match[1]))
      end

      # Fallback - bare "Month Day" anywhere in the text
      if (date_str = text[/(#{MONTH_REGEX})\s+\d{1,2}/])
        return future(Date.parse(date_str))
      end

      nil
    rescue StandardError
      nil
    end

    # Carrier SMS/email that print an explicit "MM/DD/YYYY" (or MM/DD/YY) date.
    # UPS ("Expect your … package on 08/03/2026") and USPS both do this.
    def slash_date_from(text)
      return nil if text.blank?

      match = text.match(%r{\b(\d{1,2})/(\d{1,2})/(\d{2}(?:\d{2})?)\b})
      return nil if match.nil?

      month, day, year = match.captures.map(&:to_i)
      year += 2000 if year < 100
      Date.new(year, month, day)
    rescue ArgumentError # Date::Error (invalid date) is a subclass of this
      nil
    end

    # Delivery WINDOW (two adjacent clock times) → the compact HOUR-ONLY shape
    # that AmazonOrder#delivery_time and the home.js socket parser both consume,
    # e.g. "5-7PM" from "between 5:45 PM and 7:45 PM", "4-8AM" from "4 AM – 8 AM".
    # Minutes are intentionally dropped: both consumers are hour-granular and
    # feeding them "545" as an hour breaks their date math.
    def arrival_time_from(text)
      return if text.blank?

      match = text.match(/(\d{1,2})(?::\d{2})? ?([ap])\.?m\.?\s*(?:[-–—]|to|and)\s*(\d{1,2})(?::\d{2})? ?([ap])\.?m\.?/i)
      return if match.blank?

      start_h, _start_mer, end_h, end_mer = match.captures
      "#{start_h}-#{end_h}#{end_mer.upcase}M"
    end

    # Single delivery DEADLINE ("delivering tomorrow by 9:00 PM") → "9PM", the
    # single-value form AmazonOrder#delivery_time / the frontend also handle.
    def deadline_time_from(text)
      return if text.blank?

      match = text.match(/\bby\s+(\d{1,2})(?::\d{2})? ?([ap])\.?m\.?/i)
      return if match.blank?

      "#{match[1]}#{match[2].upcase}M"
    end
  end
end
