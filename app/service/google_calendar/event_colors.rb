# Google Calendar event-color palette. The Calendar API exposes 11 numeric
# color IDs at `calendar.colors.get`; the mapping is stable and documented.
# Per-event color overrides arrive as `colorId: "<n>"` on the event payload.
module GoogleCalendar::EventColors
  PALETTE = {
    "1"  => "#a4bdfc", # Lavender
    "2"  => "#7ae7bf", # Sage
    "3"  => "#dbadff", # Grape
    "4"  => "#ff887c", # Flamingo
    "5"  => "#fbd75b", # Banana
    "6"  => "#ffb878", # Tangerine
    "7"  => "#46d6db", # Peacock
    "8"  => "#e1e1e1", # Graphite
    "9"  => "#5484ed", # Blueberry
    "10" => "#51b749", # Basil
    "11" => "#dc2127", # Tomato
  }.freeze

  def self.hex_for(color_id)
    return nil if color_id.blank?

    PALETTE[color_id.to_s]
  end
end
