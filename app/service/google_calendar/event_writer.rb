# Mirrors a user edit on a Google-synced AgendaItem back to Google
# Calendar via the events.patch / events.delete / events.insert endpoints,
# so the two views stay in sync without us depending on the next pull.
#
# Convention:
#   * Color is the ONLY field treated as a local-only override. It writes
#     to `local_color` and never propagates to Google.
#   * Every other user-visible field (name, start/end, location, notes,
#     all_day) translates to Google's payload shape and PATCHes the event.
#   * Errors bubble up; the controller is responsible for showing a
#     useful error and NOT persisting the local change on failure.
module GoogleCalendar::EventWriter
  module_function

  # Returns the mapped local_attrs + the Google-side patch body.
  # Caller is responsible for: applying local_attrs to the row only AFTER
  # the patch succeeds, and surfacing any RestClient exception.
  #
  #   local_attrs, patch_body = GoogleCalendar::EventWriter.translate(item_params)
  #
  # If the only field changed is `color`, patch_body is empty and the
  # caller can skip the Google call entirely.
  def translate(item_params)
    attrs = item_params.to_h.with_indifferent_access
    local_attrs = {}
    google_attrs = {}

    if attrs.key?(:color)
      # Color → local-only override. Sync writes Google's color into
      # `color`; UI sets `local_color` so the override survives.
      local_attrs[:local_color] = attrs[:color].presence
    end

    google_attrs[:summary]     = attrs[:name]        if attrs.key?(:name)
    google_attrs[:location]    = attrs[:location]    if attrs.key?(:location)
    google_attrs[:description] = attrs[:notes]       if attrs.key?(:notes)

    if [true, "true", "1"].include?(attrs[:all_day])
      google_attrs[:start] = { date: parse_date(attrs[:start_at]).to_s } if attrs[:start_at].present?
      google_attrs[:end]   = { date: parse_date(attrs[:end_at]).to_s }   if attrs[:end_at].present?
    else
      google_attrs[:start] = { dateTime: parse_time(attrs[:start_at]).iso8601 } if attrs[:start_at].present?
      google_attrs[:end]   = { dateTime: parse_time(attrs[:end_at]).iso8601 }   if attrs[:end_at].present?
    end

    [local_attrs, google_attrs]
  end

  def parse_date(value)
    value.is_a?(::Date) ? value : ::Date.parse(value.to_s)
  end

  def parse_time(value)
    value.is_a?(::Time) || value.is_a?(::DateTime) ? value : ::Time.zone.parse(value.to_s)
  end
end
