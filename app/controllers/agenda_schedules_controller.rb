class AgendaSchedulesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_schedule, only: [:update, :destroy]
  before_action :authorize_schedule_edit!, only: [:update, :destroy]

  def create
    target = resolve_target_agenda(params.dig(:agenda_schedule, :agenda_id))
    return render json: { errors: ["Agenda not found"] }, status: :not_found if target.blank?

    @schedule = target.agenda_schedules.new(schedule_params.except(:agenda_id))

    if @schedule.save
      target.broadcast!
      render json: { id: @schedule.id }
    else
      render json: { errors: @schedule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    new_agenda_id = schedule_params[:agenda_id]
    moved = new_agenda_id.present? && new_agenda_id.to_i != @schedule.agenda_id

    if @schedule.update(schedule_params.except(:agenda_id))
      if moved
        old_agenda = @schedule.agenda
        target = resolve_target_agenda(new_agenda_id)
        if target
          @schedule.update!(agenda_id: target.id)
          @schedule.agenda_items.update_all(agenda_id: target.id)
          # Single combined broadcast — each recipient only sees the agendas
          # they have access to. No cross-leak, no duplicate refresh.
          Agenda.broadcast_changes!([old_agenda, target])
        end
      end
      @schedule.regenerate_future!
      @schedule.agenda.broadcast! unless moved
      render json: { id: @schedule.id }
    else
      render json: { errors: @schedule.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    owning_agenda = @schedule.agenda
    @schedule.destroy
    owning_agenda.broadcast!
    head :no_content
  end

  private

  def set_schedule
    @schedule = AgendaSchedule
      .where(agenda_id: current_user.accessible_agendas.select(:id))
      .find_by(id: params[:id])
    raise ActiveRecord::RecordNotFound if @schedule.blank?
  end

  def authorize_schedule_edit!
    return if @schedule.agenda.editable_by?(current_user)

    head :forbidden
  end

  def resolve_target_agenda(agenda_id_or_slug)
    return nil if agenda_id_or_slug.blank?

    scope = current_user.editable_agendas
    scope.find_by(id: agenda_id_or_slug) || scope.by_param(agenda_id_or_slug).first
  end

  def schedule_params
    params.require(:agenda_schedule).permit(
      :agenda_id,
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
end
