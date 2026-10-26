module Buddy
  # The week's weather as a table under a Today briefing, written here rather
  # than by the companion.
  #
  # Said as prose, a forecast is a run of day names and percentages in whatever
  # order the model reaches for them, and it crowds out the parts of the day
  # that are actually news. A table reads at a glance and is the same every
  # morning, so the companion is told it is there and leaves the figures to it.
  #
  # Built from `facts[:forecast]` (Buddy::BriefingFacts#forecast), which has
  # been through the reply's metadata by the time this reads it, so a date may
  # arrive as a string.
  module ForecastTable
    module_function

    # The opening of the header row. History looks for it to take the table
    # back out of an old briefing, so the model is never shown one as
    # something it wrote.
    HEADER = "| | Home |".freeze

    WET_ICONS = { "storms" => "⛈️", "snow" => "🌨️", "rain" => "🌧️" }.freeze
    HAZE      = %w[Mist Fog Haze Smoke Dust Sand Ash].freeze

    # Below this the odds say nothing a person would plan around.
    SHOWN_ODDS = 10

    def table(rows, today:)
      rows = Array(rows).select { |row| row.is_a?(::Hash) }
      return nil if rows.empty?

      alpine = rows.any? { |row| row[:alpine].present? }
      lines  = [alpine ? "#{HEADER} Alpine |" : HEADER, alpine ? "|---|---|---|" : "|---|---|"]
      rows.each { |row|
        cells = [day_name(row[:date], today), home_cell(row)]
        cells << row[:alpine].to_s if alpine
        lines << "| #{cells.join(" | ")} |"
      }
      lines.join("\n")
    end

    # Everything from the table's header to the end of the body, which is
    # where `table` always puts it.
    def strip(body)
      text = body.to_s
      at   = text.index(/^#{Regexp.escape(HEADER)}/)
      at ? text[0...at].rstrip : text
    end

    def day_name(date, today)
      date = ::Date.parse(date.to_s) unless date.is_a?(::Date)
      date == today ? "Today" : date.strftime("%a")
    end

    def home_cell(row)
      cell = "#{icon(row)} #{row[:high]}°/#{row[:low]}°"
      wet  = WET_ICONS.key?(row[:notable].to_s)
      wet && row[:rain].to_i >= SHOWN_ODDS ? "#{cell} · #{row[:rain]}%" : cell
    end

    def icon(row)
      sky = WET_ICONS[row[:notable].to_s] || sky_icon(row)
      row[:notable].to_s == "windy" ? "#{sky} 💨" : sky
    end

    def sky_icon(row)
      return "☀️" if row[:sky] == "Clear"
      return "🌫️" if HAZE.include?(row[:sky].to_s)
      return "☁️" if row[:sky] == "Clouds" && row[:clouds].to_i >= 60

      "🌤️"
    end
  end
end
