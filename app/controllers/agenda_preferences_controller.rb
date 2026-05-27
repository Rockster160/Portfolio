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
    pref.assign_attributes(pref_params)
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
  end
end
