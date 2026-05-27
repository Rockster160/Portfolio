# Pulls events from a connected Google calendar into the AgendaItems /
# AgendaSchedules tables.
#
# Initial sync uses `timeMin = today.beginning_of_day` (current day forward
# only — no backfill). Subsequent runs pass `syncToken` and pull deltas.
# Google returns 410 Gone when a syncToken expires (~30d of inactivity);
# we catch that and re-bootstrap with a single full sync (no recursive loop).
class GoogleCalendar::Sync
  attr_reader :agenda, :user, :api

  def initialize(agenda)
    @agenda = agenda
    @user = agenda.user
    # GCal-synced agendas are scoped to a GoogleAccount that owns the
    # OAuth tokens. Pre-multi-account legacy rows may have no account
    # attached — fall back to the user-scoped API in that case (the
    # token-migration script moves them off the legacy slot).
    @api = (
      if agenda.google_account
        ::Oauth::GoogleApi.for_account(agenda.google_account)
      else
        ::Oauth::GoogleApi.new(@user)
      end
    )
  end

  # Runs an incremental sync if we have a syncToken, otherwise a full sync.
  # Persists the new syncToken on success. Returns a symbol describing the
  # outcome (:ok, :reauth_required, :rebootstrapped).
  def run!(allow_rebootstrap: true)
    page_token = nil
    sync_token = nil
    loop do
      response = fetch_page(page_token: page_token)
      return :reauth_required if response.nil?

      apply_page(response)

      sync_token = response[:nextSyncToken].presence || sync_token
      page_token = response[:nextPageToken].presence
      break unless page_token
    end

    @agenda.update!(sync_token: sync_token, synced_at: ::Time.current) if sync_token.present?
    @agenda.update!(reauth_required_at: nil) if @agenda.reauth_required_at.present?
    @agenda.google_account&.clear_reauth_required!
    @agenda.broadcast!
    :ok
  rescue ::RestClient::Gone
    # syncToken expired or invalid → bootstrap a full sync exactly once.
    return :gone_loop unless allow_rebootstrap

    @agenda.update!(sync_token: nil)
    run!(allow_rebootstrap: false)
    :rebootstrapped
  rescue ::RestClient::Unauthorized
    mark_reauth_required!
    :reauth_required
  end

  private

  def fetch_page(page_token:)
    if @agenda.sync_token.present?
      @api.list_events(
        @agenda.external_id,
        sync_token: @agenda.sync_token,
        page_token: page_token,
      )
    else
      @api.list_events(
        @agenda.external_id,
        time_min:   ::Date.current.in_time_zone(user_timezone).beginning_of_day,
        page_token: page_token,
      )
    end
  end

  # Two-pass per page: process everything that DOESN'T depend on a master
  # first (cancellations, recurring masters, one-offs), then overrides. An
  # override (`recurringEventId` present) needs its parent schedule to exist;
  # without this ordering the override silently no-ops on the first sync.
  def apply_page(payload)
    events = Array(payload[:items])
    primary, overrides = events.partition { |e| e[:recurringEventId].blank? }

    primary.each { |event| apply_event(event) }
    overrides.each { |event| apply_event(event) }
  end

  def apply_event(event)
    return if event[:id].blank?
    return handle_cancellation(event) if event[:status] == "cancelled"
    return if declined_by_owner?(event)

    if event[:recurrence].present?
      upsert_schedule(event)
    elsif event[:recurringEventId].present?
      upsert_override(event)
    else
      upsert_one_off(event)
    end
  end

  # Google sets `self: true` on the attendee whose calendar this is. If
  # they've declined, we skip the import so the event doesn't clutter the
  # agenda.
  def declined_by_owner?(event)
    Array(event[:attendees]).any? { |a| a[:self] == true && a[:responseStatus] == "declined" }
  end

  def handle_cancellation(event)
    uid = event[:id]
    sched = @agenda.agenda_schedules.find_by(external_uid: uid)
    return sched.destroy if sched

    item = @agenda.agenda_items.find_by(external_uid: uid)
    item&.destroy
  end

  def upsert_schedule(event)
    parsed = ::GoogleCalendar::RRule.translate(event[:recurrence])
    # Sub-day frequencies (HOURLY/MINUTELY) — our model has day granularity,
    # so we explicitly skip rather than creating something misleading.
    return if parsed.nil? || parsed[:skip]

    sched = @agenda.agenda_schedules.find_or_initialize_by(external_uid: event[:id])
    return if fast_skip?(sched, event)

    start_at_local = parse_event_start(event)
    all_day = all_day_event?(event)

    sched.assign_attributes(
      name:                event_summary(event),
      kind:                :event,
      color:               event_color(event),
      location:            event_location(event),
      notes:               ::GoogleCalendar::HtmlText.to_plain(event[:description]),
      start_time:          all_day ? "00:00" : start_at_local.strftime("%H:%M"),
      duration_minutes:    event_duration_minutes(event, all_day: all_day),
      starts_on:           start_at_local.to_date,
      until_on:            parsed[:until_on],
      occurrence_count:    parsed[:occurrence_count],
      recurrence:          parsed[:recurrence],
      all_day:             all_day,
      external_etag:       event[:etag],
      external_updated_at: parse_time(event[:updated]),
    )
    sched.save!
  end

  def upsert_one_off(event)
    item = @agenda.agenda_items.find_or_initialize_by(external_uid: event[:id])
    return if fast_skip?(item, event)

    start_at = parse_event_start(event)
    end_at = parse_event_end(event)
    all_day = all_day_event?(event)
    is_event = all_day || end_at.present?

    item.assign_attributes(
      name:                event_summary(event),
      kind:                is_event ? :event : :task,
      color:               event_color(event),
      start_at:            start_at,
      end_at:              is_event ? end_at : nil,
      location:            event_location(event),
      notes:               ::GoogleCalendar::HtmlText.to_plain(event[:description]),
      all_day:             all_day,
      external_etag:       event[:etag],
      external_updated_at: parse_time(event[:updated]),
    )
    item.save!
  end

  # A modified single instance of a recurring series. Google links it to
  # the master via `recurringEventId`; we materialize a detached AgendaItem
  # attached to the parent schedule. Two-pass ordering in apply_page
  # guarantees the master has been processed before we get here within a
  # single sync page.
  def upsert_override(event)
    master = @agenda.agenda_schedules.find_by(external_uid: event[:recurringEventId])
    return unless master # master not synced yet — next pass will pick it up

    item = @agenda.agenda_items.find_or_initialize_by(external_uid: event[:id])
    return if fast_skip?(item, event)

    start_at = parse_event_start(event)
    end_at = parse_event_end(event)
    all_day = all_day_event?(event)
    original_start = parse_time(
      event.dig(:originalStartTime, :dateTime) || event.dig(:originalStartTime, :date),
    )

    item.assign_attributes(
      agenda_schedule:     master,
      kind:                :event,
      name:                event_summary(event) || master.name,
      color:               event_color(event),
      start_at:            start_at,
      end_at:              end_at,
      location:            event_location(event) || master.location,
      notes:               ::GoogleCalendar::HtmlText.to_plain(event[:description]) || master.notes,
      all_day:             all_day,
      detached_at:         ::Time.current,
      original_start_at:   original_start,
      external_etag:       event[:etag],
      external_updated_at: parse_time(event[:updated]),
    )
    item.save!
  end

  # Skip the row entirely when either:
  #   * The user locally edited it (only AgendaItem has this column) — local
  #     edits win until the user disconnects + reconnects the calendar.
  #   * The etag matches what we last stored — Google is replaying a payload
  #     we already applied.
  def fast_skip?(record, event)
    return false unless record.persisted?
    return true if record.respond_to?(:locally_modified_at) && record.locally_modified_at.present?

    record.external_etag.present? && record.external_etag == event[:etag]
  end

  # ---- field extractors ----

  def event_summary(event)
    event[:summary].presence || "(no title)"
  end

  def event_color(event)
    ::GoogleCalendar::EventColors.hex_for(event[:colorId])
  end

  # Merge Google Meet / video conference link into the location field when
  # there's no explicit address. Meet links live in `conferenceData`.
  def event_location(event)
    explicit = event[:location].presence
    return explicit if explicit

    Array(event.dig(:conferenceData, :entryPoints)).each do |entry|
      uri = entry[:uri]
      next if uri.blank?

      return uri
    end
    nil
  end

  # All-day events arrive with `start.date` (YYYY-MM-DD) instead of
  # `start.dateTime`. End is the next day's date (exclusive).
  def all_day_event?(event)
    event.dig(:start, :date).present? && event.dig(:start, :dateTime).blank?
  end

  def parse_event_start(event)
    parse_time(event.dig(:start, :dateTime) || event.dig(:start, :date))
  end

  def parse_event_end(event)
    parse_time(event.dig(:end, :dateTime) || event.dig(:end, :date))
  end

  def event_duration_minutes(event, all_day:)
    s = parse_event_start(event)
    e = parse_event_end(event)
    return 24 * 60 if all_day && s && e # multi-day all-day events keep their span
    return 60 unless s && e

    [((e - s) / 60).to_i, 15].max
  end

  def parse_time(value)
    return nil if value.blank?

    ::Time.zone.parse(value.to_s)
  rescue ::ArgumentError
    nil
  end

  def user_timezone
    ::ActiveSupport::TimeZone[@user.timezone] || ::Time.zone
  end

  def mark_reauth_required!
    # Mark the GoogleAccount as needing reauth — every agenda under that
    # account is implicitly stale until the user reconnects. Fall back to
    # legacy per-agenda flag for un-migrated rows.
    @agenda.google_account&.mark_reauth_required!
    # Intentional bulk timestamp set — no model validations to skip.
    @agenda.google_account&.agendas&.update_all(reauth_required_at: ::Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
