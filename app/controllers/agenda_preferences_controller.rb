# Per-user filter prefs (hidden agendas, hide-completed by kind,
# hide-tentative, hidden recurring schedules, name regex patterns).
# Previously lived in browser localStorage; promoted to the DB so a toggle
# on phone is reflected on laptop. PATCH broadcasts the new snapshot on the
# user's monitor channel so other connected clients re-apply filters
# without a manual refresh.
class AgendaPreferencesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def show
    pref = AgendaPreference.for(current_user)
    render json: pref.serialize_for_client
  end

  def update
    pref = AgendaPreference.for(current_user)
    attrs = pref_params
    # Filter incoming hidden_agenda_ids against agendas the user can
    # actually access. Prevents a malicious / buggy client from leaving
    # stale ids in the column that point at other users' agendas or
    # nonexistent rows.
    if attrs.key?(:hidden_agenda_ids)
      allowed = current_user.accessible_agendas.pluck(:id).to_set
      attrs[:hidden_agenda_ids] = Array(attrs[:hidden_agenda_ids]).map(&:to_i).select { |id| allowed.include?(id) }
    end
    # Same sanitization for hidden_schedule_ids — restrict to schedules on
    # accessible agendas.
    if attrs.key?(:hidden_schedule_ids)
      allowed_schedule_ids = AgendaSchedule.where(agenda_id: current_user.accessible_agendas.select(:id)).pluck(:id).to_set
      attrs[:hidden_schedule_ids] = Array(attrs[:hidden_schedule_ids]).map(&:to_i).select { |id| allowed_schedule_ids.include?(id) }
    end
    # And for hidden_item_ids — accessible-agenda items only.
    if attrs.key?(:hidden_item_ids)
      allowed_item_ids = current_user.accessible_agenda_items.pluck(:id).to_set
      attrs[:hidden_item_ids] = Array(attrs[:hidden_item_ids]).map(&:to_i).select { |id| allowed_item_ids.include?(id) }
    end
    pref.assign_attributes(attrs)
    pref.user = current_user if pref.user_id.blank?
    if pref.save
      pref.broadcast!
      render json: pref.serialize_for_client
    else
      render json: { errors: pref.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def pref_params
    params
      .fetch(:agenda_preference, {})
      .permit(
        :hide_tentative,
        hidden_agenda_ids:    [],
        hidden_schedule_ids:  [],
        hidden_item_ids:      [],
        hidden_name_patterns: [],
        hide_completed:       AgendaPreference::KIND_KEYS,
      )
      .to_h
      .symbolize_keys
  end
end
