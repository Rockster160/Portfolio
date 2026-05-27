class AgendaItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_item, only: [:update, :destroy]
  before_action :authorize_item_edit!, only: [:update, :destroy]

  def create
    target = resolve_target_agenda(params.dig(:agenda_item, :agenda_id))
    return render json: { errors: ["Agenda not found"] }, status: :not_found if target.blank?

    if target.managed_externally? && item_params[:kind].to_s != "event"
      return render json: { errors: ["Only events can be added to a Google calendar."] }, status: :unprocessable_entity
    end

    base_attrs = item_params.except(:agenda_id)
    if target.managed_externally?
      # Mirror the new event to Google first. On success Google returns
      # the created event id + etag; we store those so future syncs'
      # etag fast-skip recognizes it and no double-write happens.
      _local_attrs, google_attrs = ::GoogleCalendar::EventWriter.translate(base_attrs)
      response = target.google_account.api.insert_event(target.external_id, google_attrs)
      external_attrs = {
        external_uid:        response[:id],
        external_etag:       response[:etag],
        external_updated_at: ::Time.current,
      }
      @item = target.agenda_items.new(base_attrs.merge(external_attrs))
    else
      @item = target.agenda_items.new(base_attrs)
    end

    if @item.save
      target.broadcast!
      render json: @item.serialize
    else
      render json: { errors: @item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    new_agenda_id = item_params[:agenda_id]
    moved = new_agenda_id.present? && new_agenda_id.to_i != @item.agenda_id
    target_agenda = moved ? resolve_target_agenda(new_agenda_id) : nil
    return render json: { errors: ["Agenda not found"] }, status: :not_found if moved && target_agenda.nil?

    if completion_only_update?
      # Completion is intentionally local-only — Google has no "completed"
      # state. Materializes phantom occurrences as needed.
      materialize_with(completion_attrs)
    elsif scope == :series && @item.recurring?
      apply_series_update!(moved: moved, target: target_agenda)
    else
      apply_occurrence_update!(moved: moved, target: target_agenda)
    end

    # Moves rely on AgendaItem#broadcast_agenda_change! to fan out to both
    # old + new agendas; in-place edits broadcast the one agenda here.
    @item.agenda.broadcast! unless moved
    render json: @item.serialize
  end

  def destroy
    owning_agenda = @item.agenda
    if scope == :series && @item.recurring?
      destroy_series!(owning_agenda)
    elsif @item.phantom?
      @item.agenda_schedule.add_excluded_date!(@item.occurrence_date)
      mirror_occurrence_cancel_to_google!(@item) if owning_agenda.managed_externally?
    elsif @item.recurring?
      mirror_occurrence_cancel_to_google!(@item) if owning_agenda.managed_externally?
      @item.cancel_occurrence!
    else
      # Non-recurring: full destroy + propagate the deletion upstream
      # for Google items so Google's view doesn't keep showing a row
      # we've already removed locally.
      mirror_destroy_to_google!(@item) if owning_agenda.managed_externally? && @item.external_uid.present?
      @item.destroy
    end

    owning_agenda.broadcast!
    head :no_content
  end

  # Reattaches a detached one-off back into its parent recurrence: removes
  # the original date from the schedule's excluded_dates so the phantom
  # regenerates, then destroys the detached row. Keeps the historical link
  # (agenda_schedule_id) intact up until destruction.
  #
  # For a Google-synced detached row this also deletes the Google override
  # so the upstream view restores the standard occurrence instead of
  # keeping the modified one.
  def restore
    @item = AgendaItem.locate_for_user(params[:id], current_user, editable: true)
    return head :not_found unless @item
    return head :unprocessable_entity unless @item.detached? && @item.agenda_schedule.present?

    schedule = @item.agenda_schedule
    if @item.original_start_at.present?
      original_date = @item.original_start_at.in_time_zone(@item.user.timezone).to_date
      schedule.remove_excluded_date!(original_date)
    end
    mirror_destroy_to_google!(@item) if @item.agenda.managed_externally? && @item.external_uid.present?

    owning_agenda = @item.agenda
    @item.destroy
    owning_agenda.broadcast!
    head :no_content
  end

  private

  def set_item
    @item = AgendaItem.locate_for_user(params[:id], current_user)
    raise ActiveRecord::RecordNotFound if @item.blank?
  end

  def authorize_item_edit!
    return if @item.agenda.editable_by?(current_user)

    head :forbidden
  end

  def resolve_target_agenda(agenda_id_or_slug)
    return nil if agenda_id_or_slug.blank?

    scope = current_user.editable_agendas
    scope.find_by(id: agenda_id_or_slug) || scope.by_param(agenda_id_or_slug).first
  end

  # ---- series update ----------------------------------------------------

  # Applies a "this and all future" edit to a recurring series. If the
  # source agenda is Google-synced, also PATCHes the master event upstream
  # so the two views stay aligned.
  #
  # Cross-source SERIES moves (Google ↔ local for the whole series) are
  # disallowed — Google's recurrence rules don't round-trip cleanly through
  # our local schedule shape in every case. The UI gates against this; this
  # is the server-side enforcement.
  def apply_series_update!(moved:, target:)
    if moved && cross_source_move?(@item.agenda, target)
      return render(
        json:   { errors: ["Series moves between Google and local agendas aren't supported — move occurrences individually."] },
        status: :unprocessable_entity,
      )
    end

    schedule_attrs = params[:agenda_schedule].present? ? explicit_schedule_params : schedule_attrs_from_item_params
    @item.agenda_schedule.update!(schedule_attrs)
    @item.agenda_schedule.regenerate_future!
    mirror_series_update_to_google!(@item, schedule_attrs) if @item.agenda.managed_externally?
    apply_agenda_move!(target) if moved
  end

  # Series move: shift the schedule + every materialized item to the new
  # agenda, then broadcast once for both agendas.
  def apply_agenda_move!(target)
    return unless target

    old_agenda = @item.agenda_schedule.agenda
    @item.agenda_schedule.update!(agenda_id: target.id)
    # Intentional callback skip: broadcast_agenda_change! would fire once per
    # item — we fan out a single Agenda.broadcast_changes! below instead.
    @item.agenda_schedule.agenda_items.update_all(agenda_id: target.id) # rubocop:disable Rails/SkipsModelValidations
    @item.reload
    Agenda.broadcast_changes!([old_agenda, target])
  end

  # ---- occurrence update -----------------------------------------------

  # Applies an "only this occurrence" edit. Handles four shapes:
  #   * In-place edit on a local agenda.
  #   * In-place edit on a Google-synced agenda — also PATCHes Google.
  #   * Move within the same source kind (local↔local or Google↔Google).
  #   * Move across source kinds — duplicate locally, cancel on the other
  #     side, so Google's view doesn't keep showing a deleted occurrence
  #     and the local view picks up the row as its own.
  def apply_occurrence_update!(moved:, target:)
    if moved && cross_source_move?(@item.agenda, target)
      apply_cross_source_occurrence_move!(target: target)
      return
    end

    attrs = occurrence_update_attrs
    attrs[:agenda_id] = target.id if moved
    materialize_with(attrs)
  end

  def apply_cross_source_occurrence_move!(target:)
    source = @item.agenda
    # Materialize the phantom first so we have a real row to re-parent.
    @item.materialize!({}) if @item.phantom?

    if source.managed_externally? && !target.managed_externally?
      # Google → local. Drop the upstream copy + strip the external bookkeeping.
      mirror_destroy_to_google!(@item) if @item.external_uid.present?
      @item.update!(
        agenda_id:           target.id,
        external_uid:        nil,
        external_etag:       nil,
        external_updated_at: nil,
        locally_modified_at: nil,
      )
    elsif !source.managed_externally? && target.managed_externally?
      # Local → Google. Insert upstream so future pulls round-trip.
      _local_attrs, google_attrs = ::GoogleCalendar::EventWriter.translate(@item.attributes.symbolize_keys.slice(
                                                                             :name, :start_at, :end_at, :all_day, :location, :notes
      ))
      response = target.google_account.api.insert_event(target.external_id, google_attrs)
      @item.update!(
        agenda_id:           target.id,
        external_uid:        response[:id],
        external_etag:       response[:etag],
        external_updated_at: ::Time.current,
        locally_modified_at: nil,
      )
    end
  end

  def cross_source_move?(source, target)
    source.managed_externally? != target.managed_externally?
  end

  def materialize_with(attrs)
    original_schedule = @item.agenda_schedule
    original_date = @item.occurrence_date
    # We're detaching on this save iff the row is currently attached and
    # the incoming attrs flip detached_at on. Capture the original date
    # now so we can exclude it on the parent schedule after the save.
    newly_detaching = original_schedule.present? && !@item.detached? && attrs[:detached_at].present?

    if @item.phantom?
      @item.materialize!(attrs)
    else
      @item.update!(attrs)
    end

    original_schedule.add_excluded_date!(original_date) if newly_detaching
  end

  def occurrence_update_attrs
    attrs = item_params.except(:agenda_id).to_h
    # First time we detach an occurrence, stamp detached_at and remember
    # the original start_at so "Restore to cycle" knows which date to put
    # the row back on. Keep agenda_schedule_id intact for the historical
    # link — items_for_range honors detached_at to avoid suppressing the
    # parent schedule's phantom on the row's current date.
    if @item.recurring? && !@item.detached?
      attrs[:detached_at] = Time.current
      attrs[:original_start_at] = @item.start_at
    end

    # Externally-synced item: send name/time/location/etc to Google via
    # patch_event AND apply them locally so the UI reflects the change
    # immediately. We capture the response etag so the next sync skips
    # cleanly via the etag fast path.
    #
    # Color is the one exception: it's a local-only override stored in
    # `local_color`. We translate `color` → `local_color` and drop the
    # original key so we don't try to overwrite Google's colorId.
    if @item.agenda.managed_externally?
      local_attrs, google_attrs = ::GoogleCalendar::EventWriter.translate(attrs)
      patched = mirror_to_google!(google_attrs) if google_attrs.any?
      attrs = attrs.except(:color).merge(local_attrs)
      # Stamp the local-edit time so the sync compares against this when
      # deciding whether to overwrite — see GoogleCalendar::Sync#fast_skip?.
      attrs[:locally_modified_at] = ::Time.current
      # Carry Google's authoritative etag/updated forward — without this
      # the next sync sees a stale etag and falls through to the timestamp
      # comparison every time.
      if patched.is_a?(::Hash)
        attrs[:external_etag] = patched[:etag] if patched[:etag].present?
        attrs[:external_updated_at] = Time.zone.parse(patched[:updated].to_s) if patched[:updated].present?
      end
    end
    attrs
  end

  # ---- destroy helpers -------------------------------------------------

  def destroy_series!(owning_agenda)
    sched = @item.agenda_schedule
    cutoff_date = @item.occurrence_date
    cutoff_time = @item.start_at

    if owning_agenda.managed_externally? && sched.external_uid.present?
      # Truncate the upstream series so the master remains for history but
      # stops generating future instances after cutoff. Google's RRULE
      # `UNTIL` is exclusive — we send the cutoff day's start as the
      # boundary so today's already-fired occurrence survives.
      mirror_series_truncate_to_google!(owning_agenda, sched, cutoff_date)
    end

    sched.update!(occurrence_count: nil, until_on: cutoff_date - 1)
    # Cascade-cancel future materialized rows instead of destroying —
    # keeps history; views filter via `not_cancelled`.
    sched.agenda_items.where(start_at: cutoff_time..).update_all( # rubocop:disable Rails/SkipsModelValidations
      status:       AgendaItem.statuses[:cancelled],
      cancelled_at: Time.current,
    )
  end

  def mirror_to_google!(google_attrs)
    @item.agenda.google_account.api.patch_event(
      @item.agenda.external_id,
      @item.external_uid,
      google_attrs,
    )
  end

  def mirror_destroy_to_google!(item)
    item.agenda.google_account.api.delete_event(item.agenda.external_id, item.external_uid)
  rescue ::RestClient::NotFound, ::RestClient::Gone
    # Already gone upstream — nothing to undo.
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] delete failed agenda=#{item.agenda.id} uid=#{item.external_uid} #{e.class}: #{e.message}")
  end

  def mirror_occurrence_cancel_to_google!(item)
    sched = item.agenda_schedule
    return if sched&.external_uid.blank?

    # Sending status: cancelled on a synthetic instance id tells Google "this
    # one occurrence is removed." For a phantom we don't have an instance id
    # yet — derive it from the master + occurrence date in the format Google
    # expects (`{eventId}_{YYYYMMDD or UTC}`).
    instance_id = item.external_uid.presence || derived_instance_id(sched.external_uid, item.occurrence_date, item.all_day?)
    return if instance_id.blank?

    item.agenda.google_account.api.patch_event(
      item.agenda.external_id,
      instance_id,
      { status: "cancelled" },
    )
  rescue ::RestClient::NotFound, ::RestClient::Gone
    # Already absent upstream.
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] occurrence-cancel failed agenda=#{item.agenda.id} #{e.class}: #{e.message}")
  end

  # Google instance id convention: `{masterEventId}_{YYYYMMDD}` for all-day,
  # `{masterEventId}_{YYYYMMDDTHHMMSSZ}` for timed. We always know the date;
  # for timed we don't always know the start time precisely (phantoms don't
  # round-trip), so fall back to the master id + date — Google accepts the
  # date form for timed series occurrences too in most cases. Bare-master
  # form is a safety net the patch will reject if Google can't resolve it,
  # at which point we'll just log.
  def derived_instance_id(master_uid, date, all_day)
    return nil if date.blank?

    suffix = date.strftime("%Y%m%d")
    suffix += "T000000Z" unless all_day
    "#{master_uid}_#{suffix}"
  end

  def mirror_series_update_to_google!(item, schedule_attrs)
    sched = item.agenda_schedule
    return if sched.external_uid.blank?

    body = {}
    body[:summary]     = schedule_attrs[:name]     if schedule_attrs.key?(:name)
    body[:location]    = schedule_attrs[:location] if schedule_attrs.key?(:location)
    body[:description] = schedule_attrs[:notes]    if schedule_attrs.key?(:notes)
    if schedule_attrs[:start_time].present? && sched.starts_on.present?
      zone = ::ActiveSupport::TimeZone[item.user.timezone] || Time.zone
      hour, min = schedule_attrs[:start_time].to_s.split(":").map(&:to_i)
      start_at = zone.local(sched.starts_on.year, sched.starts_on.month, sched.starts_on.day, hour || 0, min || 0)
      end_at   = start_at + (schedule_attrs[:duration_minutes] || sched.duration_minutes || 60).minutes
      body[:start] = { dateTime: start_at.iso8601 }
      body[:end]   = { dateTime: end_at.iso8601 }
    end
    # RRULE round-trip lives in GoogleCalendar::RRule; series-rule editing
    # to Google is a follow-up — for now we PATCH the metadata Google
    # accepts trivially and leave recurrence to the next user-initiated
    # rule change (which the UI will land via the next sync round-trip).
    return if body.empty?

    response = item.agenda.google_account.api.patch_event(
      item.agenda.external_id,
      sched.external_uid,
      body,
    )
    if response.is_a?(::Hash)
      sched.update!(
        external_etag:       response[:etag] || sched.external_etag,
        external_updated_at: response[:updated].present? ? Time.zone.parse(response[:updated].to_s) : sched.external_updated_at,
      )
    end
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] series PATCH failed agenda=#{item.agenda.id} #{e.class}: #{e.message}")
  end

  def mirror_series_truncate_to_google!(agenda, sched, cutoff_date)
    # PATCH the master event with a new RRULE ending at cutoff_date - 1.
    # We rebuild from the locally-known recurrence rather than try to read
    # back from Google — our local schedule is the source of truth once
    # the user has hit "delete future."
    rrule_lines = ::GoogleCalendar::RRule.serialize(sched, until_on: cutoff_date - 1)
    return if rrule_lines.blank?

    agenda.google_account.api.patch_event(
      agenda.external_id,
      sched.external_uid,
      { recurrence: rrule_lines },
    )
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] series truncate failed agenda=#{agenda.id} #{e.class}: #{e.message}")
  end

  def item_params
    params.require(:agenda_item).permit(
      :agenda_id, :name, :kind, :color, :local_color, :start_at, :end_at, :all_day,
      :notes, :location, :completed_at, :trigger_expression
    )
  end

  def explicit_schedule_params
    params.require(:agenda_schedule).permit(
      :name,
      :kind,
      :color,
      :start_time,
      :duration_minutes,
      :starts_on,
      :until_on,
      :occurrence_count,
      :notes,
      :location,
      :trigger_expression,
      recurrence: [:freq, :interval, :unit, :by_set_pos, { by_day: [], by_month_day: [], excluded_dates: [] }],
    )
  end

  def scope
    params[:scope].to_s.to_sym.presence_in([:occurrence, :series]) || :occurrence
  end

  def completion_only_update?
    keys = params.fetch(:agenda_item, {}).keys.map(&:to_s)
    keys.present? && (keys - %w[completed_at]).empty?
  end

  def completion_attrs
    raw = params[:agenda_item][:completed_at]
    val = if raw.blank? || raw.to_s == "false"
      nil
    else
      (raw == "now" ? Time.current : raw)
    end
    { completed_at: val }
  end

  def schedule_attrs_from_item_params
    attrs = {}
    attrs[:name] = item_params[:name] if item_params[:name].present?
    attrs[:notes] = item_params[:notes] if item_params.key?(:notes)
    attrs[:location] = item_params[:location] if item_params.key?(:location)
    attrs[:color] = item_params[:color] if item_params[:color].present?
    attrs[:trigger_expression] = item_params[:trigger_expression] if item_params.key?(:trigger_expression)
    if item_params[:start_at].present?
      t = Time.zone.parse(item_params[:start_at].to_s)
      attrs[:start_time] = t.strftime("%H:%M") if t
    end
    if item_params[:end_at].present? && item_params[:start_at].present?
      s = Time.zone.parse(item_params[:start_at].to_s)
      e = Time.zone.parse(item_params[:end_at].to_s)
      attrs[:duration_minutes] = ((e - s) / 60).to_i if s && e
    end
    attrs
  end
end
