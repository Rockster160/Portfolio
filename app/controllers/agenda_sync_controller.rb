class AgendaSyncController < ApplicationController
  before_action :authorize_user_or_guest

  # How far back the initial bootstrap looks for materialized items. Older
  # history is lazy-loaded via #page when the user navigates earlier than
  # the cached floor — keeps the bootstrap payload bounded regardless of
  # account age.
  BOOTSTRAP_PAST_WINDOW = 30.days
  # Hard cap on #page's range so a buggy client can't pull years of items
  # in a single request.
  MAX_PAGE_RANGE_DAYS = 366
  # Matches `data-day-start-hour` on .cal-week-grid. Surfaced in the
  # bootstrap payload so the JS recurrence expander and the FE renderer
  # use the same logical-day rollover as the server.
  DAY_START_HOUR = 3

  # Full client-side state snapshot for the Agenda PWA. Boots the
  # AgendaStore in the browser so every subsequent page navigation
  # (prev/next week, jump months ahead) is a local computation against
  # the cached agendas+schedules+items. Materialized items load from
  # `today − BOOTSTRAP_PAST_WINDOW` forward; recurring schedules send
  # their rules and the JS expander builds phantoms for any future date.
  def bootstrap
    window_start = (current_user.perceived_today - BOOTSTRAP_PAST_WINDOW).to_date

    render json: {
      server_ts:             current_server_ts,
      day_key:               current_user.perceived_today.iso8601,
      timezone:              current_user.timezone,
      day_start_hour:        DAY_START_HOUR,
      window:                { from: window_start.iso8601, to: nil },
      agendas:               serialized_agendas,
      preferences:           AgendaPreference.for(current_user).serialize_for_client,
      notification_settings: serialized_notification_settings,
      schedules:             serialized_schedules(active_from: window_start),
      items:                 serialized_items(window_start, nil),
      carry_over_ids:        current_user.agenda_carry_over_items.pluck(:id),
    }
  end

  # Incremental sync. `?since=<iso8601>` returns every accessible item
  # and schedule whose `updated_at` is on or after the cutoff. Upsert-
  # only — destroys are signalled through Monitor broadcasts in real
  # time, and a bootstrap re-pull is the authoritative resync for any
  # destroy the client missed (e.g. offline). Cancelled items DO come
  # through here so the client can prune local renders.
  def delta
    since = parse_since(params[:since])
    return render(json: { error: "since required (iso8601)" }, status: :bad_request) if since.blank?

    render json: {
      server_ts: current_server_ts,
      day_key:   current_user.perceived_today.iso8601,
      since:     since.iso8601,
      agendas:   serialized_agendas, # cheap; broadcast misses are rare but real
      schedules: serialized_schedules(updated_since: since),
      items:     serialized_items_since(since),
    }
  end

  # Authoritative range backfill. Used when the user navigates earlier
  # than the bootstrap window's `from` (lazy historical fetch). The FE
  # treats the returned items as the canonical set for the window —
  # anything it had cached inside [from..to] that's NOT in the response
  # gets dropped. Cancelled rows excluded; this is a render-facing pull.
  def page
    from = parse_date(params[:from])
    to   = parse_date(params[:to])
    if from.blank? || to.blank? || to < from
      return render(json: { error: "from and to (YYYY-MM-DD) required, to >= from" }, status: :bad_request)
    end
    if (to - from).to_i > MAX_PAGE_RANGE_DAYS
      return render(json: { error: "range exceeds #{MAX_PAGE_RANGE_DAYS}-day cap" }, status: :bad_request)
    end

    render json: {
      server_ts: current_server_ts,
      day_key:   current_user.perceived_today.iso8601,
      window:    { from: from.iso8601, to: to.iso8601 },
      schedules: serialized_schedules(active_from: from, active_to: to),
      items:     serialized_items(from, to),
    }
  end

  private

  # Epoch milliseconds — race-guard cutoff for the FE store's reconcile
  # logic. ms granularity matches what the Chores store already uses.
  def current_server_ts
    (Time.current.to_f * 1000).to_i
  end

  def editable_agenda_ids
    @editable_agenda_ids ||= current_user.editable_agendas.pluck(:id).to_set
  end

  def serialized_agendas
    current_user.accessible_agendas.order(:sort_order, :id).map { |a|
      {
        id:                   a.id,
        name:                 a.name,
        color:                a.color,
        slug:                 a.parameterized_name,
        source:               a.source,
        sort_order:           a.sort_order,
        editable:             editable_agenda_ids.include?(a.id),
        managed_externally:   a.managed_externally?,
      }
    }
  end

  def serialized_notification_settings
    AgendaNotificationSetting.where(user_id: current_user.id).map { |s|
      {
        agenda_id:                s.agenda_id,
        notify_task_oneoff:       s.notify_task_oneoff,
        notify_task_recurring:    s.notify_task_recurring,
        notify_event_oneoff:      s.notify_event_oneoff,
        notify_event_recurring:   s.notify_event_recurring,
        notify_trigger_oneoff:    s.notify_trigger_oneoff,
        notify_trigger_recurring: s.notify_trigger_recurring,
      }
    }
  end

  # Three modes:
  #   active_from (open-ended):       schedules effective on/after that date
  #   active_from + active_to:        schedules overlapping the date range
  #   updated_since:                  schedules touched on/after timestamp
  # `editable` is merged on for FE permission gating.
  def serialized_schedules(active_from: nil, active_to: nil, updated_since: nil)
    scope = AgendaSchedule.where(agenda_id: current_user.accessible_agendas.select(:id))
    if active_from
      to = active_to || (active_from + 100.years)
      scope = scope.active_between(active_from, to)
    end
    scope = scope.where("agenda_schedules.updated_at >= ?", updated_since) if updated_since
    scope.map { |s|
      s.serialize_for_client.merge(editable: editable_agenda_ids.include?(s.agenda_id))
    }
  end

  # Materialized rows whose effective time span overlaps the requested
  # window. `to_date=nil` means "open-ended forward" — used by bootstrap
  # so the FE caches every known future item up front.
  #
  # `.includes(:agenda, :agenda_schedule)` is essential — `AgendaItem#serialize`
  # → `presentation_attrs` reads `agenda.name/color/source` and
  # `agenda_schedule&.serialize_for_edit` per item; without the preloads
  # bootstrap fires N+1 on each association.
  def serialized_items(from_date, to_date)
    zone = ::ActiveSupport::TimeZone[current_user.timezone] || ::Time.zone
    range_start = zone.local(from_date.year, from_date.month, from_date.day).beginning_of_day
    range_end = to_date && zone.local(to_date.year, to_date.month, to_date.day).end_of_day

    scope = current_user.accessible_agenda_items.not_cancelled
      .includes(:agenda, :agenda_schedule)
    scope = scope.where("COALESCE(end_at, start_at) >= ?", range_start)
    scope = scope.where("start_at <= ?", range_end) if range_end
    scope.order(:start_at).map { |i|
      i.serialize.merge(editable: editable_agenda_ids.include?(i.agenda_id))
    }
  end

  # Delta variant — includes cancelled rows on purpose so the FE prunes
  # locally-rendered events that the user / Google cancelled while the
  # client was offline. The store uses `status: cancelled` as the prune
  # signal. Same eager-load contract as serialized_items above.
  def serialized_items_since(since)
    current_user.accessible_agenda_items
      .includes(:agenda, :agenda_schedule)
      .where("agenda_items.updated_at >= ?", since)
      .order(:updated_at)
      .map { |i| i.serialize.merge(editable: editable_agenda_ids.include?(i.agenda_id)) }
  end

  def parse_since(str)
    return nil if str.blank?

    ::Time.iso8601(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_date(str)
    return nil if str.blank?

    ::Date.parse(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
