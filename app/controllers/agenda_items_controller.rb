class AgendaItemsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_item, only: [:update, :destroy]
  before_action :authorize_item_edit!, only: [:update, :destroy]

  def create
    target = resolve_target_agenda(params.dig(:agenda_item, :agenda_id))
    return render json: { errors: ["Agenda not found"] }, status: :not_found if target.blank?

    @item = target.agenda_items.new(item_params.except(:agenda_id))

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

    if completion_only_update?
      materialize_with(completion_attrs)
    elsif scope == :series && @item.recurring?
      # Use the explicit schedule payload when present (full recurrence
      # config), otherwise derive from the item params so simple name/time
      # edits still work.
      schedule_attrs = params[:agenda_schedule].present? ? explicit_schedule_params : schedule_attrs_from_item_params
      @item.agenda_schedule.update!(schedule_attrs)
      @item.agenda_schedule.regenerate_future!
      apply_agenda_move!(new_agenda_id) if moved
    else
      attrs = occurrence_update_attrs
      attrs[:agenda_id] = new_agenda_id if moved
      materialize_with(attrs)
    end

    # Moves rely on AgendaItem#broadcast_agenda_change! to fan out to both
    # old + new agendas; in-place edits broadcast the one agenda here.
    @item.agenda.broadcast! unless moved
    render json: @item.serialize
  end

  def destroy
    owning_agenda = @item.agenda
    if scope == :series && @item.recurring?
      sched = @item.agenda_schedule
      cutoff_date = @item.occurrence_date
      cutoff_time = @item.start_at
      sched.update!(occurrence_count: nil, until_on: cutoff_date - 1)
      sched.agenda_items.where(start_at: cutoff_time..).destroy_all
    elsif @item.phantom?
      @item.agenda_schedule.add_excluded_date!(@item.occurrence_date)
    elsif @item.recurring?
      @item.cancel_occurrence!
    else
      @item.destroy
    end

    owning_agenda.broadcast!
    head :no_content
  end

  # Reattaches a detached one-off back into its parent recurrence: removes
  # the original date from the schedule's excluded_dates so the phantom
  # regenerates, then destroys the detached row. Keeps the historical link
  # (agenda_schedule_id) intact up until destruction.
  def restore
    @item = AgendaItem.locate_for_user(params[:id], current_user, editable: true)
    return head :not_found unless @item
    return head :unprocessable_entity unless @item.detached? && @item.agenda_schedule.present?

    schedule = @item.agenda_schedule
    if @item.original_start_at.present?
      original_date = @item.original_start_at.in_time_zone(@item.user.timezone).to_date
      schedule.remove_excluded_date!(original_date)
    end

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

  # Series move: shift the schedule + every materialized item to the new
  # agenda, then broadcast once for both agendas.
  def apply_agenda_move!(new_agenda_id)
    target = resolve_target_agenda(new_agenda_id)
    return unless target

    old_agenda = @item.agenda_schedule.agenda
    @item.agenda_schedule.update!(agenda_id: target.id)
    @item.agenda_schedule.agenda_items.update_all(agenda_id: target.id)
    @item.reload
    Agenda.broadcast_changes!([old_agenda, target])
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
    attrs
  end

  def item_params
    params.require(:agenda_item).permit(
      :agenda_id, :name, :kind, :color, :start_at, :end_at, :notes, :location,
      :completed_at, :trigger_expression
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
