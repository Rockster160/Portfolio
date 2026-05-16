class AgendaNotificationSettingsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_agenda

  def update
    setting = AgendaNotificationSetting.find_or_initialize_by(user: current_user, agenda: @agenda)
    setting.assign_attributes(setting_params)
    if setting.save
      render json: serialize(setting)
    else
      render json: { errors: setting.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  # Per-user pref, so anyone with view access can configure their own.
  def set_agenda
    @agenda = current_user.accessible_agendas.find_by(id: params[:agenda_id]) ||
              current_user.accessible_agendas.by_param(params[:agenda_id]).first
    raise ActionController::RoutingError, "Not Found" if @agenda.blank?
  end

  def setting_params
    params.require(:agenda_notification_setting).permit(
      :notify_task_oneoff, :notify_task_recurring,
      :notify_event_oneoff, :notify_event_recurring,
      :notify_trigger_oneoff, :notify_trigger_recurring,
    )
  end

  def serialize(setting)
    {
      agenda_id:                setting.agenda_id,
      notify_task_oneoff:       setting.notify_task_oneoff,
      notify_task_recurring:    setting.notify_task_recurring,
      notify_event_oneoff:      setting.notify_event_oneoff,
      notify_event_recurring:   setting.notify_event_recurring,
      notify_trigger_oneoff:    setting.notify_trigger_oneoff,
      notify_trigger_recurring: setting.notify_trigger_recurring,
    }
  end
end
