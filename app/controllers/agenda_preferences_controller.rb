# Per-user filter prefs (hidden agendas, hide-completed by kind,
# hide-tentative). Previously lived in browser localStorage; promoted to
# the DB so a toggle on phone is reflected on laptop. PATCH broadcasts the
# new snapshot on the user's monitor channel so other connected clients
# re-apply filters without a manual refresh.
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
    pref.assign_attributes(attrs)
    pref.user = current_user if pref.user_id.blank?
    pref.save!
    pref.broadcast!
    render json: pref.serialize_for_client
  end

  private

  def pref_params
    params
      .fetch(:agenda_preference, {})
      .permit(:hide_tentative, hidden_agenda_ids: [], hide_completed: AgendaPreference::KIND_KEYS)
      .to_h
      .symbolize_keys
  end
end
