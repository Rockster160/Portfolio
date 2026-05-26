class AgendaConnectionsController < ApplicationController
  before_action :authorize_user_or_guest

  # GET /agenda_connection/start/google
  # Kicks off the OAuth round-trip. The callback at /webhooks/oauth/google_api
  # exchanges the code and redirects back to #new, which then has a token
  # cached and can fetch the user's calendar list.
  def start_google
    redirect_to(google.auth_url, allow_other_host: true)
  end

  # GET /agenda_connection/new
  # Post-OAuth picker: lists the user's Google calendars with checkboxes for
  # which ones to import. Externally-managed agendas already present are
  # surfaced as pre-selected (re-pick is a no-op).
  def new
    unless google_authenticated?
      @needs_auth = true
      return
    end

    list = google.list_calendars
    if list.blank?
      @error = "Could not load your Google Calendars. Try reconnecting."
      @needs_auth = true
      return
    end

    @calendars = Array(list[:items]).map { |c|
      {
        external_id: c[:id],
        name:        c[:summary],
        description: c[:description],
        time_zone:   c[:timeZone],
        color:       c[:backgroundColor],
        primary:     c[:primary] == true,
      }
    }
    already = current_user.agendas.google.where(external_id: @calendars.pluck(:external_id))
    @already_connected = already.index_by(&:external_id)
  end

  # POST /agenda_connection
  # Imports each selected calendar as an Agenda + enqueues an initial sync.
  def create
    raw = params.fetch(:calendars, {}).respond_to?(:to_unsafe_h) ? params[:calendars].to_unsafe_h : params[:calendars]
    selected = (raw || {}).select { |_id, attrs| attrs.is_a?(Hash) && attrs[:enabled].to_s == "1" }
    if selected.empty?
      redirect_to(new_agenda_connection_path, alert: "Pick at least one calendar to import.")
      return
    end

    imported = selected.map { |external_id, attrs|
      agenda = current_user.agendas.find_or_initialize_by(
        source: :google, external_id: external_id,
      )
      agenda.name ||= attrs[:name].presence || "Google Calendar"
      agenda.color ||= attrs[:color].presence || Agenda::DEFAULT_COLOR
      agenda.save!
      ::GoogleCalendarSyncWorker.perform_async(agenda.id)
      agenda
    }

    redirect_to(manage_agenda_path, notice: "Importing #{imported.size} #{"calendar".pluralize(imported.size)}…")
  end

  # DELETE /agenda_connection
  # Disconnect: stops every active watch channel, revokes the OAuth token,
  # and (when ?delete_data=1) destroys the synced agendas + their items.
  def destroy
    current_user.agendas.google.find_each do |agenda|
      ::GoogleCalendar::WatchManager.stop!(agenda) if agenda.watch_channel_id.present?
    end
    google.revoke!

    if params[:delete_data].to_s == "1"
      current_user.agendas.google.destroy_all
    end

    redirect_to(manage_agenda_path, notice: "Google Calendar disconnected.")
  end

  private

  def google
    @google ||= ::Oauth::GoogleApi.new(current_user)
  end

  def google_authenticated?
    google.access_token.present?
  end
end
