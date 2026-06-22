class AgendaItemsController < ApplicationController
  # Raised by any mirror-to-Google helper that fails in a way the user
  # needs to know about (PATCH/INSERT/DELETE rejected, instance not
  # resolvable, etc.). Caught at the top of every action; the local row
  # is left untouched and the user sees the message instead of a silent
  # divergence between our view and Google's.
  class GoogleSyncFailed < StandardError; end

  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_item, only: [:update, :destroy]
  before_action :authorize_item_edit!, only: [:update, :destroy]
  before_action :reject_stale_client_mutation!, only: [:update, :destroy]

  rescue_from GoogleSyncFailed, with: :render_google_sync_failed

  def create
    target = resolve_target_agenda(params.dig(:agenda_item, :agenda_id))
    return render json: { errors: ["Agenda not found"] }, status: :not_found if target.blank?

    # Idempotency: if the FE retries (offline queue, double-tap, two tabs)
    # the same client_mutation_id, return the row we already created
    # instead of duplicating. The unique partial index on agenda_items
    # makes a concurrent retry safe even if both reach the controller.
    mutation_id = client_mutation_id
    if mutation_id.present?
      existing = current_user.accessible_agenda_items.find_by(client_mutation_id: mutation_id)
      if existing
        render json: existing.serialize.merge(deduped: true)
        return
      end
    end

    if target.managed_externally? && item_params[:kind].to_s != "event"
      return render json: { errors: ["Only events can be added to a Google calendar."] }, status: :unprocessable_entity
    end

    base_attrs = item_params.except(:agenda_id)
    base_attrs[:client_mutation_id] = mutation_id if mutation_id.present?
    with_agenda_write_lock(target) {
      if target.managed_externally?
        # Mirror to Google FIRST. If it fails, we never touch the local
        # table — the user sees the error and nothing has diverged.
        _local_attrs, google_attrs = ::GoogleCalendar::EventWriter.translate(base_attrs.except(:client_mutation_id))
        response = google_insert!(target, google_attrs)
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
    }
  end

  def update
    # Idempotency: if this exact mutation was already applied to this row
    # (FE retry after a network drop), short-circuit with the canonical
    # current row. Without this, a replayed PATCH would re-broadcast and
    # re-run after_commit hooks for a no-op.
    mutation_id = client_mutation_id
    if mutation_id.present? && @item.client_mutation_id == mutation_id
      render json: @item.serialize.merge(deduped: true)
      return
    end

    new_agenda_id = item_params[:agenda_id]
    moved = new_agenda_id.present? && new_agenda_id.to_i != @item.agenda_id
    target_agenda = moved ? resolve_target_agenda(new_agenda_id) : nil
    return render json: { errors: ["Agenda not found"] }, status: :not_found if moved && target_agenda.nil?

    landing_agenda = target_agenda || @item.agenda
    # Mirrors the create-time guard: Google calendars only hold events,
    # so refuse any update that would leave the row in a Google agenda
    # with a non-event kind (whether via in-place edit or cross-source move).
    if landing_agenda.managed_externally? && item_params[:kind].present? && item_params[:kind].to_s != "event"
      return render json: { errors: ["Only events can be added to a Google calendar."] }, status: :unprocessable_entity
    end

    with_agenda_write_lock(@item.agenda, target_agenda) {
      if completion_only_update?
        # Completion is intentionally local-only — Google has no "completed"
        # state. Materializes phantom occurrences as needed.
        materialize_with(completion_attrs)
      elsif scope == :series && @item.recurring?
        apply_series_update!(moved: moved, target: target_agenda)
      else
        apply_occurrence_update!(moved: moved, target: target_agenda)
      end
      # `apply_series_update!` may have rendered a 422 for an unsupported
      # cross-source series move. Skip the trailing broadcast + render in
      # that case so we don't hit AbstractController::DoubleRenderError.
      next if performed?

      # Moves rely on AgendaItem#broadcast_agenda_change! to fan out to both
      # old + new agendas; in-place edits broadcast the one agenda here.
      @item.agenda.broadcast! unless moved
      render json: @item.serialize
    }
  end

  def destroy
    owning_agenda = @item.agenda
    destroyed_ids = []
    with_agenda_write_lock(owning_agenda) {
      if scope == :series && @item.recurring?
        destroy_series!(owning_agenda)
      elsif @item.phantom?
        # Cancel upstream FIRST so a Google rejection doesn't leave the
        # local excluded_dates ahead of Google.
        mirror_occurrence_cancel_to_google!(@item) if owning_agenda.managed_externally?
        @item.agenda_schedule.add_excluded_date!(@item.occurrence_date)
      elsif @item.recurring?
        mirror_occurrence_cancel_to_google!(@item) if owning_agenda.managed_externally?
        @item.cancel_occurrence!
      else
        # Non-recurring: propagate the deletion upstream first, then
        # destroy locally so a Google failure leaves the row intact.
        # Capture the display_id BEFORE destroy so the broadcast can carry
        # it — the FE delta endpoint is upsert-only and can't tell the
        # store the row is gone otherwise.
        mirror_destroy_to_google!(@item) if owning_agenda.managed_externally? && @item.external_uid.present?
        destroyed_ids << @item.display_id
        @item.destroy
      end

      owning_agenda.broadcast!(destroyed_item_ids: destroyed_ids)
      head :no_content
    }
  end

  # Reattaches a detached one-off back into its parent recurrence: removes
  # the original date from the schedule's excluded_dates so the phantom
  # regenerates, then destroys the detached row. Keeps the historical link
  # (agenda_schedule_id) intact up until destruction.
  #
  # For a Google-synced detached row this also deletes the Google override
  # so the upstream view restores the standard occurrence instead of
  # keeping the modified one.
  # RSVP to a Google-synced event. Patches the connected account's
  # responseStatus upstream first (no email blast — `sendUpdates=none`),
  # then mirrors locally into AgendaItem.metadata.self_response. Phantoms
  # are materialized + detached so the response applies to THIS occurrence
  # only — matches the per-occurrence editing model the rest of the
  # controller uses.
  RESPONSE_STATUSES = %w[accepted tentative declined needsAction].freeze

  def respond
    @item = AgendaItem.locate_for_user(params[:id], current_user, editable: true)
    return head :not_found unless @item
    return render json: { errors: ["Not a Google-synced event."] }, status: :unprocessable_entity unless @item.agenda.managed_externally?

    response_status = params[:response].to_s
    return render json: { errors: ["Unknown response."] }, status: :unprocessable_entity if RESPONSE_STATUSES.exclude?(response_status)

    with_agenda_write_lock(@item.agenda) {
      new_attendees = updated_attendees_for_self(response_status)
      instance_id = mirror_rsvp_to_google!(@item, new_attendees)
      apply_rsvp_locally!(@item, instance_id, new_attendees, response_status)

      @item.agenda.broadcast!
      render json: @item.serialize
    }
  end

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
    destroyed_id = @item.display_id
    @item.destroy
    owning_agenda.broadcast!(destroyed_item_ids: [destroyed_id])
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
    # Apply locally first (the RRULE serializer reads from `sched.recurrence`),
    # then PATCH Google. If Google rejects, raise + the action's
    # `rescue_from` catches and renders. The local update is wrapped in a
    # transaction so a failed Google PATCH rolls it back.
    occurrence_date = @item.occurrence_date
    sched = @item.agenda_schedule
    ActiveRecord::Base.transaction do
      sched.update!(schedule_attrs)
      sched.regenerate_future!
      mirror_series_update_to_google!(@item, schedule_attrs) if @item.agenda.managed_externally?
    end
    # `regenerate_future!` may have destroyed @item itself — re-resolve so
    # the action's trailing render has a row (real or phantom) to serialize.
    @item = resolve_item_after_series_update(sched, occurrence_date)
    apply_agenda_move!(target) if moved
  end

  # Series move within the same source kind:
  #   * local → local: pure DB re-parent.
  #   * Google → Google (SAME account): call Google's events.move so the
  #     upstream master gets re-homed too; then re-parent locally.
  #   * Google → Google (DIFFERENT account): refuse — Google's move
  #     endpoint requires both calendars under the same OAuth identity.
  #     Cross-account would require delete + recreate of the entire
  #     series, which would lose Google-side instance overrides.
  def apply_agenda_move!(target)
    return unless target

    sched = @item.agenda_schedule
    old_agenda = sched.agenda

    if old_agenda.managed_externally? && target.managed_externally?
      if old_agenda.google_account_id != target.google_account_id
        raise GoogleSyncFailed, "Series moves between different Google accounts aren't supported — " \
                                "move occurrences individually or recreate the series in the target calendar."
      end
      mirror_series_move_to_google!(old_agenda, target, sched)
    end

    occurrence_date = @item.occurrence_date
    sched.update!(agenda_id: target.id)
    # Intentional callback skip: broadcast_agenda_change! would fire once per
    # item — we fan out a single Agenda.broadcast_changes! below instead.
    sched.agenda_items.update_all(agenda_id: target.id) # rubocop:disable Rails/SkipsModelValidations
    # The original @item row may have been destroyed by
    # `regenerate_future!` during the preceding series update — re-resolve
    # via the schedule + date so the action's downstream `@item.serialize`
    # has a row to render (either the re-fetched row, or a fresh phantom
    # for the same occurrence date).
    @item = resolve_item_after_series_update(sched, occurrence_date)
    Agenda.broadcast_changes!([old_agenda, target])
  end

  # After a series edit that destroys/replaces materialized rows, find a
  # stand-in for the original @item: a live row that occupies the same
  # date, or a phantom built from the updated schedule.
  def resolve_item_after_series_update(sched, occurrence_date)
    sched.reload
    same_date = sched.agenda_items.where(
      start_at: sched.agenda.send(:day_range, occurrence_date),
    ).first
    return same_date if same_date

    sched.matches?(occurrence_date) ? sched.build_phantom(occurrence_date) : @item
  end

  # Move the master upstream via Google's events.move endpoint. Captures
  # the response etag so the next sync skips this row via the etag fast
  # path. Raises GoogleSyncFailed on rejection so the caller can render a
  # user-visible error.
  def mirror_series_move_to_google!(source_agenda, target_agenda, sched)
    return if sched.external_uid.blank?

    response = source_agenda.google_account.api.move_event(
      source_agenda.external_id,
      sched.external_uid,
      target_agenda.external_id,
    )
    return unless response.is_a?(::Hash)

    sched.update!(
      external_etag:       response[:etag] || sched.external_etag,
      external_updated_at: response[:updated].present? ? Time.zone.parse(response[:updated].to_s) : sched.external_updated_at,
    )
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] series move failed src=#{source_agenda.id} dst=#{target_agenda.id} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, google_error_message(e, "move the series")
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

    if source.managed_externally? && !target.managed_externally?
      cross_source_move_google_to_local!(target: target)
    elsif !source.managed_externally? && target.managed_externally?
      cross_source_move_local_to_google!(target: target)
    end
  end

  # Google → local. Cancel the specific occurrence upstream (so Google
  # stops showing it) AND add the date to the source schedule's local
  # excluded_dates (otherwise the source agenda renders a ghost phantom
  # until the next sync re-confirms the cancellation). Decouple the row
  # from the source schedule + clear external bookkeeping. For a one-off
  # we delete the event outright.
  #
  # Local mutations are wrapped in a transaction so a DB failure rolls
  # back the materialization. Google's cancellation isn't rolled back on
  # local failure — eventual consistency takes over.
  def cross_source_move_google_to_local!(target:)
    if @item.recurring?
      source_schedule = @item.agenda_schedule
      occurrence_date = @item.occurrence_date
      mirror_occurrence_cancel_to_google!(@item)
      ActiveRecord::Base.transaction do
        source_schedule&.add_excluded_date!(occurrence_date)
        @item.materialize!({}) if @item.phantom?
        @item.update!(
          agenda_id:           target.id,
          agenda_schedule_id:  nil,
          detached_at:         nil,
          original_start_at:   nil,
          external_uid:        nil,
          external_etag:       nil,
          external_updated_at: nil,
          locally_modified_at: nil,
        )
      end
    else
      mirror_destroy_to_google!(@item) if @item.external_uid.present?
      @item.update!(
        agenda_id:           target.id,
        external_uid:        nil,
        external_etag:       nil,
        external_updated_at: nil,
        locally_modified_at: nil,
      )
    end
  end

  # Local → Google. Insert upstream first, then commit the local re-parent
  # + external_* fields. Transactionally so the phantom materialization
  # rolls back if Google rejects the insert.
  # Tasks and triggers can't live in Google agendas (Google only holds
  # events), so the row is coerced to :event during the move. The
  # update-action's kind guard catches the case where the user passed an
  # explicit `kind` param — this catches the silent path where they only
  # changed `agenda_id` and the existing kind was task/trigger.
  def cross_source_move_local_to_google!(target:)
    ActiveRecord::Base.transaction do
      @item.materialize!({}) if @item.phantom?
      @item.kind = :event unless @item.event?
      attrs_for_google = @item.attributes.symbolize_keys.slice(
        :name, :start_at, :end_at, :all_day, :location, :notes
      )
      # Google events require an end_at — local tasks may not have one.
      # Default to start_at + 30min so the insert always succeeds.
      attrs_for_google[:end_at] ||= (attrs_for_google[:start_at] + 30.minutes if attrs_for_google[:start_at])
      _local_attrs, google_attrs = ::GoogleCalendar::EventWriter.translate(attrs_for_google)
      response = google_insert!(target, google_attrs)
      @item.update!(
        agenda_id:           target.id,
        kind:                :event,
        end_at:              attrs_for_google[:end_at],
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
      # Truncate the upstream series FIRST so a Google rejection doesn't
      # leave our copy already truncated while Google still generates the
      # series forever. RRULE `UNTIL` is exclusive — we send cutoff-1.
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

  # Wraps the controller mutation path in the same advisory lock that
  # GoogleCalendar::Sync uses, serializing user-driven writes against an
  # in-flight sync of the same Google agenda. For local-only agendas the
  # lock is a no-op (we just yield).
  # Handles up to two distinct Google agendas (e.g. cross-source move where
  # both source + target are Google). Always acquires in id-order to avoid
  # the deadlock window two simultaneous opposite-direction moves would
  # otherwise carve out.
  #
  # On timeout (sync genuinely taking longer than 30s) the gem returns a
  # `WithAdvisoryLock::Result` with `lock_was_acquired? == false`. We
  # surface a 503 with a retry hint instead of an empty 500.
  # We use the `_result` variant rather than the bare `with_advisory_lock`
  # because the latter conflates "block returned falsy" with "timeout."
  def with_agenda_write_lock(*agendas, &block)
    keys = agendas.compact.select(&:managed_externally?).map(&:id).uniq.sort.map { |id| "gcal_sync:agenda:#{id}" }
    return block.call if keys.empty?

    acquired = acquire_locks(keys, block)
    return render_lock_timeout! unless acquired

    nil
  end

  def acquire_locks(remaining, blk)
    return (blk.call || true) if remaining.empty?

    inner_acquired = nil
    result = Agenda.with_advisory_lock_result(remaining.first, 30) {
      inner_acquired = acquire_locks(remaining[1..], blk)
    }
    return false unless result.lock_was_acquired?

    inner_acquired
  end

  def render_lock_timeout!
    render json: { errors: ["Calendar is busy syncing right now — please retry in a moment."] }, status: :service_unavailable
  end

  # `belongs_to :google_account, optional: true` lets an externally-managed
  # agenda exist with a nil account (hard-deleted account, prod data copied
  # into dev without the matching google_accounts row, etc.). Raise the same
  # error the upstream API failures use so the caller gets a clean 422
  # instead of a NoMethodError.
  def assert_google_account!(agenda)
    return if agenda.google_account.present?

    raise GoogleSyncFailed, "This calendar isn't connected to Google right now. Reconnect it from Manage Agendas to make changes."
  end

  def google_insert!(target, google_attrs)
    assert_google_account!(target)
    target.google_account.api.insert_event(target.external_id, google_attrs)
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] insert failed agenda=#{target.id} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, google_error_message(e, "create the event")
  end

  def mirror_to_google!(google_attrs)
    assert_google_account!(@item.agenda)
    @item.agenda.google_account.api.patch_event(
      @item.agenda.external_id,
      @item.external_uid,
      google_attrs,
    )
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] patch failed agenda=#{@item.agenda.id} uid=#{@item.external_uid} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, google_error_message(e, "save your changes")
  end

  def mirror_destroy_to_google!(item)
    assert_google_account!(item.agenda)
    item.agenda.google_account.api.delete_event(item.agenda.external_id, item.external_uid)
  rescue ::RestClient::NotFound, ::RestClient::Gone
    # Already gone upstream — treat as success.
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] delete failed agenda=#{item.agenda.id} uid=#{item.external_uid} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, google_error_message(e, "delete the event")
  end

  # Synthesize a user-friendly error from Google's 4xx body when possible,
  # falling back to a class-name hint. Avoids leaking the full stack trace
  # while still pointing at the cause (most often "you don't own this
  # calendar so we can't write it").
  def google_error_message(error, verb)
    code = error.respond_to?(:http_code) ? error.http_code : nil
    case code
    when 403 then "Google refused to #{verb} — you may not have permission on this calendar."
    when 404 then "Google couldn't find the event — it may have been deleted upstream."
    when 410 then "This event is gone from Google. Refresh to see the latest."
    when 429 then "Google rate-limited the request — please try again in a moment."
    else "Couldn't #{verb} on Google (#{error.class.name.demodulize})."
    end
  end

  def render_google_sync_failed(exception)
    render json: { errors: [exception.message] }, status: :bad_gateway
  end

  # Builds the attendees array to send back to Google: existing attendees
  # with self's responseStatus replaced. If the connected account isn't
  # already in the list (e.g. invite landed before we synced) we insert it
  # so the response actually lands.
  def updated_attendees_for_self(response_status)
    account_email = @item.agenda.google_account.email.to_s.downcase
    existing = @item.attendees.map(&:to_h)
    found = false
    updated = existing.map { |a|
      if a["self"] == true || a["email"].to_s.downcase == account_email
        found = true
        a.merge("response_status" => response_status, "self" => true)
      else
        a
      end
    }
    updated << { "email" => account_email, "self" => true, "response_status" => response_status } unless found
    updated
  end

  # PATCHes Google with the new attendees list. For phantoms we resolve
  # the Google instance id first (matches the cancel-occurrence pattern).
  # Returns the Google event id we actually wrote against (caller stores
  # it on a newly-materialized row so future patches don't re-resolve).
  def mirror_rsvp_to_google!(item, attendees)
    instance_id = item.external_uid.presence
    if instance_id.blank?
      instance_id = resolve_google_instance_id(item, item.agenda_schedule) if item.agenda_schedule&.external_uid.present?
      raise GoogleSyncFailed, "Couldn't find the matching event on Google Calendar." if instance_id.blank?
    end

    body = { attendees: attendees.map { |a| google_attendee_payload(a) } }
    item.agenda.google_account.api.patch_event(
      item.agenda.external_id,
      instance_id,
      body,
    )
    instance_id
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] rsvp failed agenda=#{item.agenda.id} uid=#{instance_id} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, google_error_message(e, "send your response")
  end

  def google_attendee_payload(attendee)
    {
      email:          attendee["email"],
      displayName:    attendee["display_name"],
      responseStatus: attendee["response_status"],
      organizer:      attendee["organizer"],
      optional:       attendee["optional"],
      self:           attendee["self"],
    }.compact
  end

  # Persists the new self_response. Phantoms materialize as detached so the
  # response applies to this occurrence only — Google PATCHed the instance,
  # not the master, so the rest of the series stays untouched. Status
  # mirrors `event_status` for the new response: `tentative` flips status;
  # anything else (accepted/declined/needsAction) stays :confirmed and the
  # UI uses metadata.self_response for the badge / decline treatment.
  def apply_rsvp_locally!(item, instance_id, attendees, response_status)
    new_metadata = item.metadata.to_h.merge(
      "attendees"     => attendees,
      "self_response" => response_status,
    )
    new_status = response_status == "tentative" ? :tentative : :confirmed

    attrs = {
      metadata:            new_metadata,
      status:              new_status,
      locally_modified_at: Time.current,
    }
    # Phantom branch: detach into a materialized row so the per-occurrence
    # RSVP doesn't leak back into the schedule's metadata for every future
    # phantom on the same series.
    if item.phantom?
      attrs[:detached_at]       = Time.current
      attrs[:original_start_at] = item.start_at
      attrs[:external_uid]      = instance_id
      original_date = item.occurrence_date
      original_schedule = item.agenda_schedule
      item.materialize!(attrs)
      original_schedule.add_excluded_date!(original_date)
    elsif item.recurring? && !item.detached? && item.external_uid.blank?
      attrs[:detached_at]       = Time.current
      attrs[:original_start_at] = item.start_at
      attrs[:external_uid]      = instance_id
      item.update!(attrs)
    else
      attrs[:external_uid] = instance_id if item.external_uid.blank?
      item.update!(attrs)
    end
  end

  def mirror_occurrence_cancel_to_google!(item)
    sched = item.agenda_schedule
    return if sched&.external_uid.blank?

    instance_id = item.external_uid.presence || resolve_google_instance_id(item, sched)
    raise GoogleSyncFailed, "Couldn't find the matching occurrence on Google Calendar." if instance_id.blank?

    item.agenda.google_account.api.patch_event(
      item.agenda.external_id,
      instance_id,
      { status: "cancelled" },
    )
  rescue ::RestClient::NotFound, ::RestClient::Gone
    # Already absent upstream — treat as success.
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] occurrence-cancel failed agenda=#{item.agenda.id} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, "Google rejected the occurrence cancellation: #{e.class}."
  end

  # Ask Google directly which instance id corresponds to the occurrence
  # we're cancelling. We query a narrow window around the occurrence (one
  # full day in the user's tz) and pick the instance whose
  # `originalStartTime` lands on our date. Falls back to nil on any error
  # — caller raises a user-visible failure when that happens.
  def resolve_google_instance_id(item, sched)
    user_tz = ::ActiveSupport::TimeZone[item.user.timezone] || ::Time.zone
    date = item.occurrence_date
    window_start = user_tz.local(date.year, date.month, date.day).beginning_of_day
    window_end   = window_start.end_of_day

    response = item.agenda.google_account.api.list_event_instances(
      item.agenda.external_id,
      sched.external_uid,
      time_min: window_start,
      time_max: window_end,
    )
    return nil unless response.is_a?(::Hash)

    instances = Array(response[:items])
    # Prefer an exact match on originalStartTime; fall back to whatever
    # single instance the window returned.
    match = instances.find { |inst|
      stamp = inst.dig(:originalStartTime, :date) || inst.dig(:originalStartTime, :dateTime)
      stamp.present? && Time.zone.parse(stamp.to_s).in_time_zone(item.user.timezone).to_date == date
    }
    (match || instances.first)&.[](:id)
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] instance lookup failed agenda=#{item.agenda.id} #{e.class}: #{e.message}")
    nil
  end

  # PATCH the Google master event with everything we can map from the
  # local schedule: summary / location / description / start+end / RRULE.
  # Called when the user edits a series ("this and all future"); raises
  # GoogleSyncFailed on a Google rejection so the local update can be
  # skipped at the call site.
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
    # Push RRULE too whenever the explicit schedule payload is present —
    # otherwise a user-driven recurrence change would land locally and
    # get clobbered by the next sync pull.
    if schedule_attrs[:recurrence].present? || schedule_attrs[:until_on].present? || schedule_attrs[:occurrence_count].present?
      rrule_lines = ::GoogleCalendar::RRule.serialize(sched)
      body[:recurrence] = rrule_lines if rrule_lines.present?
    end
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
    response
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] series PATCH failed agenda=#{item.agenda.id} #{e.class}: #{e.message}")
    raise GoogleSyncFailed, google_error_message(e, "save the series")
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
    raise GoogleSyncFailed, google_error_message(e, "truncate the series")
  end

  def item_params
    raw = params.require(:agenda_item).permit(
      :agenda_id, :name, :kind, :color, :local_color, :start_at, :end_at, :all_day,
      :notes, :location, :arrive_early_minutes, :completed_at, :trigger_expression,
      :client_mutation_id
    )

    # Time fields cross the wire as integer epoch seconds (UTC) so the FE
    # owns timezone interpretation end-to-end. Convert here so the rest of
    # the controller + AR see proper Time values.
    [:start_at, :end_at, :completed_at].each do |key|
      raw[key] = epoch_param_to_time(raw[key]) if raw.key?(key)
    end
    raw
  end

  # Accepts: nil, "", integer, integer-string. Anything else returns nil and
  # logs (likely a stale client sending an ISO string from a pre-epoch build).
  def epoch_param_to_time(val)
    return nil if val.blank?
    return ::Time.at(val.to_i) if val.is_a?(::Numeric) || val.to_s.match?(/\A-?\d+\z/)

    ::Rails.logger.warn("[agenda_items_controller] non-epoch time param: #{val.inspect}")
    nil
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
      :arrive_early_minutes,
      :trigger_expression,
      :all_day,
      recurrence: [:freq, :interval, :unit, :by_set_pos, { by_day: [], by_month_day: [], excluded_dates: [] }],
    )
  end

  def scope
    params[:scope].to_s.to_sym.presence_in([:occurrence, :series]) || :occurrence
  end

  def completion_only_update?
    # `client_mutation_id` is metadata the FE attaches to every mutation —
    # it's not a field change, so it doesn't disqualify the completion-only
    # fast path. Without this allowance, the controller falls through to
    # `apply_occurrence_update!` where `item_params` runs `epoch_param_to_time`
    # on the sentinel string `"now"` and silently writes nil to completed_at.
    keys = params.fetch(:agenda_item, {}).keys.map(&:to_s) - %w[client_mutation_id]
    keys.present? && (keys - %w[completed_at]).empty?
  end

  def completion_attrs
    raw = params[:agenda_item][:completed_at]
    val = if raw.blank? || raw.to_s == "false"
      nil
    elsif raw == "now"
      Time.current
    else
      epoch_param_to_time(raw)
    end
    attrs = { completed_at: val }
    # Persist the mutation id so a replayed PATCH (FE retry after a network
    # drop) short-circuits via the dedup check at the top of `update` instead
    # of re-running after_commit hooks + re-broadcasting.
    if (mid = client_mutation_id).present?
      attrs[:client_mutation_id] = mid
    end
    attrs
  end

  def schedule_attrs_from_item_params
    attrs = {}
    attrs[:name] = item_params[:name] if item_params[:name].present?
    attrs[:notes] = item_params[:notes] if item_params.key?(:notes)
    attrs[:location] = item_params[:location] if item_params.key?(:location)
    attrs[:arrive_early_minutes] = item_params[:arrive_early_minutes] if item_params.key?(:arrive_early_minutes)
    attrs[:color] = item_params[:color] if item_params[:color].present?
    attrs[:trigger_expression] = item_params[:trigger_expression] if item_params.key?(:trigger_expression)
    attrs[:all_day] = item_params[:all_day] if item_params.key?(:all_day)
    # item_params has already coerced start_at / end_at to Time. The
    # schedule's `start_time` column is a wall-clock time-of-day, so
    # render in the server-anchored user zone (Denver) — this is the only
    # spot the server is allowed to pick a display zone, because it has
    # to materialize a tz-naive HH:MM for the recurrence rule.
    if (s = item_params[:start_at])
      zone = ::ActiveSupport::TimeZone[current_user.timezone] || ::Time.zone
      attrs[:start_time] = s.in_time_zone(zone).strftime("%H:%M")
      if (e = item_params[:end_at])
        attrs[:duration_minutes] = ((e - s) / 60).to_i
      end
    end
    attrs
  end

  # Extracts the client_mutation_id from either the request body
  # (`agenda_item.client_mutation_id`, the queue's natural payload home)
  # or a top-level `client_mutation_id` param (RSVP / completion flows
  # that don't nest under :agenda_item). Returns nil for non-PWA
  # callers so legacy paths keep working untouched.
  def client_mutation_id
    raw = params.dig(:agenda_item, :client_mutation_id) || params[:client_mutation_id]
    raw.presence
  end

  # X-Client-Mutation-At carries the wall-clock instant (epoch ms) when
  # the user actually made the change. The JS queue stamps this on
  # enqueue, so a 2pm offline edit replayed at 2:45pm still arrives with
  # `client_ts: 2pm`. If we find the row has been touched by another
  # device since then (another tab, another phone, Google sync),
  # short-circuit with 409 Conflict + the canonical current row so the
  # client can prune its stale op + replace its local copy. The JS queue
  # treats 4xx as permanent and pushes the op into `agendaDroppedOps`
  # for the dismissable banner — the user sees that something didn't
  # apply.
  #
  # Skipped when the header is missing (browsers that don't set it,
  # server-side test specs that don't simulate it) so existing flows
  # keep working.
  def reject_stale_client_mutation!
    raw = request.headers["X-Client-Mutation-At"]
    return if raw.blank?

    client_ms = Integer(raw, 10)
    server_ms = (@item.updated_at.to_f * 1000).round
    return if client_ms >= server_ms

    # Phantoms have no persisted updated_at to compare against — fall
    # through so the materialization can run as a fresh write.
    return if @item.respond_to?(:phantom?) && @item.phantom?

    render json: {
      errors: ["Stale write — server has a newer version of this item."],
      current: @item.serialize.merge(editable: @item.agenda.editable_by?(current_user)),
    }, status: :conflict
  rescue ArgumentError
    # Malformed header — ignore silently rather than 500.
    nil
  end
end
