# Pulls events from a connected Google calendar into the AgendaItems /
# AgendaSchedules tables.
#
# Initial sync uses `timeMin = today.beginning_of_day` (current day forward
# only — no backfill). Subsequent runs pass `syncToken` and pull deltas.
# Google returns 410 Gone when a syncToken expires (~30d of inactivity);
# we catch that and re-bootstrap with a single full sync (no recursive loop).
class GoogleCalendar::Sync
  # conferenceData entry types. Prefer video — that's what users click to
  # join. Phone-only is a fallback for calendars without a video entry.
  VIDEO_ENTRY_TYPES = %w[video].freeze
  PHONE_ENTRY_TYPES = %w[phone sip].freeze

  # Thread-local key that suppresses AgendaItem#fire_jil_trigger inside a
  # sync run, AND coalesces per-agenda broadcasts into a single one at the
  # tail. Read by AgendaItem; toggled here.
  SUPPRESS_KEY = :gcal_sync_suppress_jil_triggers

  attr_reader :agenda, :user, :api

  def initialize(agenda)
    @agenda = agenda
    @user = agenda.user
    @account = agenda.google_account
    raise ArgumentError, "Agenda ##{agenda.id} has no google_account — orphan row" if @account.nil?

    @api = ::Oauth::GoogleApi.for_account(@account)
  end

  # Runs an incremental sync if we have a syncToken, otherwise a full sync.
  # Persists the new syncToken on success. Returns a symbol describing the
  # outcome (:ok, :reauth_required, :rebootstrapped).
  # `reason` is recorded on the agenda so the manage page can label a
  # sync as "via webhook" vs "via poll" — useful for debugging at a
  # glance. Defaults to :manual when invoked from the console.
  #
  # The advisory lock dedupes concurrent runs against the same agenda:
  # a webhook delivery and the 15-minute poll cron firing at the same
  # moment both end up here, both reading the same sync_token. With the
  # lock, the second worker waits, then sees the bumped sync_token and
  # short-circuits via etag-skip. Without it, both racewrite the same
  # rows.
  def run!(allow_rebootstrap: true, reason: :manual)
    lock_key = "gcal_sync:agenda:#{@agenda.id}"
    Agenda.with_advisory_lock(lock_key, 30) {
      run_synced(allow_rebootstrap: allow_rebootstrap, reason: reason)
    }
  end

  private

  def run_synced(allow_rebootstrap:, reason:)
    @deferred_overrides = []      # buffered across pages — see flush_deferred
    @deferred_cancellations = []  # ditto for cancellation handle_cancellation
    @applied_count = 0            # counted across apply_event for the tail trigger
    ensure_timezone!
    page_token = nil
    sync_token = nil

    # Suppress per-row Jil triggers + per-row Agenda broadcasts for the
    # duration of the sync. We fan out ONE broadcast + ONE :agenda_sync
    # trigger at the tail.
    with_suppression {
      loop do
        response = fetch_page(page_token: page_token)
        return :reauth_required if response.nil?

        apply_page(response)

        sync_token = response[:nextSyncToken].presence || sync_token
        page_token = response[:nextPageToken].presence
        break unless page_token
      end

      flush_deferred_cancellations
      flush_deferred_overrides
    }

    # Persist synced_at on EVERY successful run — even if Google returned
    # no nextSyncToken (rare, e.g. immediately after a full re-sync that
    # paginated to exactly the end). The UI's "Synced X ago" depends on
    # this; don't gate it on sync_token presence.
    @agenda.update!(
      sync_token:  sync_token.presence || @agenda.sync_token,
      synced_at:   ::Time.current,
      sync_reason: reason.to_s,
    )
    @account.clear_reauth_required!
    @agenda.broadcast!
    # Single :agenda_sync trigger at the tail (per-row :agenda_item
    # triggers were suppressed above). Lets Jil tasks react to "the
    # calendar just refreshed" without firing once per imported event.
    # Skipped on no-op syncs — Google's webhook + 15-min poll cron
    # generate plenty of empty deltas, no reason to spam listeners.
    if @applied_count.positive?
      sync_data = { agenda_id: @agenda.id, agenda_name: @agenda.name, reason: reason.to_s, applied: @applied_count }
      ::Jil.trigger(@user, :agenda_sync, sync_data)
    end
    :ok
  rescue ::RestClient::Gone
    # syncToken expired or invalid → bootstrap a full sync exactly once.
    return :gone_loop unless allow_rebootstrap

    @agenda.update!(sync_token: nil)
    run!(allow_rebootstrap: false, reason: reason)
    :rebootstrapped
  rescue ::RestClient::Unauthorized
    mark_reauth_required!
    :reauth_required
  end

  def with_suppression
    Thread.current[SUPPRESS_KEY] = true
    yield
  ensure
    Thread.current[SUPPRESS_KEY] = nil
  end

  # Lazily populate the calendar's timezone the first time we sync after a
  # connect. Used to translate "all-day on May 28" into a concrete instant.
  # Network / API failure logs + carries on (tz fetch is best-effort —
  # all-day handling falls back to user.timezone). Programmer errors
  # propagate so they don't get masked.
  def ensure_timezone!
    return if @agenda.timezone.present?

    response = @api.get_calendar(@agenda.external_id)
    tz = response.is_a?(::Hash) ? response[:timeZone].to_s.presence : nil
    @agenda.update!(timezone: tz) if tz
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar::Sync] timezone fetch failed agenda=#{@agenda.id} #{e.class}: #{e.message}")
  end

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

  # Two-pass per page: process events that DON'T depend on a master first,
  # then overrides for masters we've already seen. If an override's master
  # is on a LATER page, buffer the override into @deferred_overrides; we
  # replay them after pagination finishes, by which point every master
  # has been written.
  def apply_page(payload)
    events = Array(payload[:items])
    primary, overrides = events.partition { |e| e[:recurringEventId].blank? }

    primary.each { |event| apply_event(event) }
    overrides.each do |event|
      master = @agenda.agenda_schedules.find_by(external_uid: event[:recurringEventId])
      if master
        apply_event(event)
      elsif event[:status] == "cancelled"
        @deferred_cancellations << event
      else
        @deferred_overrides << event
      end
    end
  end

  # Final replay pass — overrides whose master arrived on a later page.
  # Anything still without a master is logged for visibility.
  def flush_deferred_overrides
    return if @deferred_overrides.blank?

    @deferred_overrides.each do |event|
      master = @agenda.agenda_schedules.find_by(external_uid: event[:recurringEventId])
      if master
        apply_event(event)
      else
        ::Rails.logger.warn(
          "[GoogleCalendar::Sync] override without master agenda=#{@agenda.id} " \
          "override=#{event[:id]} master=#{event[:recurringEventId]}",
        )
      end
    end
    @deferred_overrides = []
  end

  # Cancellations referencing a master that hadn't been seen yet. Replay
  # after pagination — the master may have been deleted in the same batch
  # (status=cancelled on its own row), in which case we still want the
  # excluded_dates bookkeeping to land.
  def flush_deferred_cancellations
    return if @deferred_cancellations.blank?

    @deferred_cancellations.each { |event| handle_cancellation(event) }
    @deferred_cancellations = []
  end

  def apply_event(event)
    return if event[:id].blank?
    if event[:status] == "cancelled"
      handle_cancellation(event)
      @applied_count += 1
      return
    end
    return if declined_by_owner?(event)

    # upsert_* return truthy when they actually persisted a change and
    # falsy when fast_skip short-circuited. Only the truthy case counts
    # toward `:agenda_sync`'s applied total.
    persisted = (
      if event[:recurrence].present?
        upsert_schedule(event)
      elsif event[:recurringEventId].present?
        upsert_override(event)
      else
        upsert_one_off(event)
      end
    )
    @applied_count += 1 if persisted
  end

  # Google sets `self: true` on the attendee whose calendar this is. If
  # they've declined, we skip the import so the event doesn't clutter the
  # agenda.
  def declined_by_owner?(event)
    Array(event[:attendees]).any? { |a| a[:self] == true && a[:responseStatus] == "declined" }
  end

  # Maps a Google event to its AgendaItem status enum.
  #   * Google flags it `tentative` directly → :tentative.
  #   * Connected user hasn't fully accepted (needsAction/tentative) → :tentative.
  #   * Otherwise → :confirmed.
  # `cancelled` is handled separately by handle_cancellation — by the time
  # we reach this writer the event is confirmed-or-tentative.
  def event_status(event)
    return :tentative if event[:status] == "tentative"

    self_attendee = Array(event[:attendees]).find { |a| a[:self] == true }
    return :confirmed if self_attendee.nil?

    %w[needsAction tentative].include?(self_attendee[:responseStatus]) ? :tentative : :confirmed
  end

  # `status: cancelled` arrives in three shapes:
  #   1. A recurring master is deleted entirely. → destroy the schedule
  #      (cascades override items via dependent: :destroy).
  #   2. A one-off event is deleted. → destroy the item.
  #   3. A single instance of a recurring series is deleted (`recurringEventId`
  #      present, no item materialized). → add the date to the master's
  #      excluded_dates so the phantom no longer regenerates. If we DID
  #      materialize an override row, destroy it too.
  def handle_cancellation(event)
    uid = event[:id]
    sched = @agenda.agenda_schedules.find_by(external_uid: uid)
    return sched.destroy if sched

    item = @agenda.agenda_items.find_by(external_uid: uid)

    # Single-occurrence cancellation — exclude its date on the master so
    # the phantom doesn't regenerate.
    if event[:recurringEventId].present?
      master = @agenda.agenda_schedules.find_by(external_uid: event[:recurringEventId])
      if master.nil?
        # Master is on a later page; replay after pagination finishes.
        @deferred_cancellations << event unless @deferred_cancellations.include?(event)
        return
      end

      occurrence_date = all_day_event?(event) ? parse_event_date(event.dig(:originalStartTime, :date)) : parse_time(event.dig(:originalStartTime, :dateTime))&.in_time_zone(user_timezone)&.to_date
      master.add_excluded_date!(occurrence_date) if occurrence_date
    end

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
    # Guard: parse can return nil for malformed dates. Skip the row entirely
    # + Slack so we know about it. Without this, the strftime below
    # NoMethodError's and the entire sync page fails silently.
    return report_malformed_event!(event, "missing start_at") if start_at_local.nil?

    all_day = all_day_event?(event)
    # Merge any locally-recorded excluded_dates back into the new recurrence
    # so a Google-edit to the master rule doesn't wipe out per-occurrence
    # cancellations we already know about.
    merged_recurrence = parsed[:recurrence].dup
    existing = sched.persisted? ? sched.excluded_dates.map(&:to_s) : []
    inbound  = Array(merged_recurrence[:excluded_dates]).map(&:to_s)
    union    = (existing + inbound).uniq
    merged_recurrence[:excluded_dates] = union if union.any?

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
      recurrence:          merged_recurrence,
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
    # Google Calendar items are always events. If the inbound payload is
    # missing `end` (rare — point-in-time events), default to a 30-min
    # span so the AgendaItem :end_at_required_for_event validation passes.
    end_at ||= (start_at + 30.minutes if start_at)
    attrs = {
      name:                event_summary(event),
      kind:                :event,
      color:               event_color(event),
      start_at:            start_at,
      end_at:              end_at,
      location:            event_location(event),
      notes:               ::GoogleCalendar::HtmlText.to_plain(event[:description]),
      all_day:             all_day,
      status:              event_status(event),
      external_etag:       event[:etag],
      external_updated_at: parse_time(event[:updated]),
    }
    # Google's update is newer than our local edit — accept the inbound
    # change AND clear the local-edit flag so future Google pulls aren't
    # forever blocked by a stale stamp.
    attrs[:locally_modified_at] = nil if item.persisted? && item.locally_modified_at.present?
    item.assign_attributes(attrs)
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
    original_start = (
      if all_day_event?(event)
        parse_event_date(event.dig(:originalStartTime, :date))&.then { |d| user_timezone.local(d.year, d.month, d.day) }
      else
        parse_time(event.dig(:originalStartTime, :dateTime))
      end
    )

    attrs = {
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
    }
    attrs[:locally_modified_at] = nil if item.persisted? && item.locally_modified_at.present?
    item.assign_attributes(attrs)
    item.save!
  end

  # Skip the row entirely when either:
  #   * The user locally edited it MORE RECENTLY than Google's reported
  #     `updated` timestamp — our edit is newer, ignore the stale inbound
  #     copy until either Google moves forward past us or the user touches
  #     the row again.
  #   * The etag matches what we last stored — Google is replaying a payload
  #     we already applied.
  def fast_skip?(record, event)
    return false unless record.persisted?

    if record.respond_to?(:locally_modified_at) && record.locally_modified_at.present?
      remote_updated = parse_time(event[:updated])
      return true if remote_updated.nil? || remote_updated <= record.locally_modified_at
    end

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
  # there's no explicit address. See VIDEO_ENTRY_TYPES / PHONE_ENTRY_TYPES
  # at the top of the class for ordering rationale.
  def event_location(event)
    explicit = event[:location].presence
    return explicit if explicit

    entries = Array(event.dig(:conferenceData, :entryPoints))
    video = entries.find { |e| VIDEO_ENTRY_TYPES.include?(e[:entryPointType].to_s) && e[:uri].present? }
    return video[:uri] if video

    phone = entries.find { |e| PHONE_ENTRY_TYPES.include?(e[:entryPointType].to_s) && e[:uri].present? }
    return phone[:uri] if phone

    # No typed entry but something has a uri — last-resort fallback.
    entries.find { |e| e[:uri].present? }&.[](:uri)
  end

  # All-day events arrive with `start.date` (YYYY-MM-DD) instead of
  # `start.dateTime`. End is the next day's date (exclusive).
  def all_day_event?(event)
    event.dig(:start, :date).present? && event.dig(:start, :dateTime).blank?
  end

  # All-day: parse the date and interpret midnight IN THE USER'S TZ so
  # `start_at.in_time_zone(user.timezone).to_date` always returns Google's
  # date — regardless of where the calendar / worker / user live.
  # Timed: RFC3339 string carries its own offset; Time.zone.parse is faithful.
  def parse_event_start(event)
    if all_day_event?(event)
      d = parse_event_date(event.dig(:start, :date))
      return nil if d.nil?

      user_timezone.local(d.year, d.month, d.day)
    else
      parse_time(event.dig(:start, :dateTime))
    end
  end

  def parse_event_end(event)
    if all_day_event?(event)
      d = parse_event_date(event.dig(:end, :date))
      return nil if d.nil?

      user_timezone.local(d.year, d.month, d.day)
    else
      parse_time(event.dig(:end, :dateTime))
    end
  end

  def event_duration_minutes(event, all_day:)
    s = parse_event_start(event)
    e = parse_event_end(event)
    return 60 unless s && e
    return ((e - s) / 60).to_i if all_day

    [((e - s) / 60).to_i, 15].max
  end

  def parse_event_date(value)
    return nil if value.blank?

    ::Date.parse(value.to_s)
  rescue ::ArgumentError
    nil
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
    @account.mark_reauth_required!
  end

  # Skip + log + Slack-notify a single event we can't parse cleanly.
  # Continuing the sync past one bad event is intentional — we don't want
  # one malformed Google payload to wedge the entire calendar.
  def report_malformed_event!(event, reason)
    ::Rails.logger.warn(
      "[GoogleCalendar::Sync] skipping malformed event agenda=#{@agenda.id} " \
      "event=#{event[:id]} reason=#{reason}",
    )
    return unless ::Rails.env.production?

    ::SlackNotifier.notify(
      "GoogleCalendar::Sync skipped event for agenda=#{@agenda.id} " \
      "event=#{event[:id]} reason=#{reason}",
    ) rescue nil
    nil
  end
end
