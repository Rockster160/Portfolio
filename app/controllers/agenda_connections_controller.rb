class AgendaConnectionsController < ApplicationController
  before_action :authorize_user_or_guest

  # GET /agenda_connection/start/google
  # Kicks off the OAuth round-trip. The callback at /webhooks/oauth/google_api
  # exchanges the code and redirects back to #new — at which point we have
  # a cached token and can render the calendar picker.
  def start_google
    redirect_to(google.auth_url, allow_other_host: true)
  end

  # GET /agenda_connection/new
  #   * Not authed → render the "Sign in with Google" CTA.
  #   * Authed → render the picker: every calendar from the user's
  #     CalendarList, marked as Connected (Agenda already exists) or
  #     "Connect" button (not yet imported). One click per row, no bulk
  #     form submit.
  def new
    unless google_authenticated?
      @needs_auth = true
      return
    end

    list = google.list_calendars
    if list.blank? || Array(list[:items]).empty?
      flash[:alert] = "Could not load your Google Calendars. Try reconnecting."
      redirect_to(manage_agenda_path)
      return
    end

    @calendars = Array(list[:items]).map { |c|
      {
        external_id: c[:id],
        name:        c[:summary],
        time_zone:   c[:timeZone],
        color:       c[:backgroundColor],
        primary:     c[:primary] == true,
      }
    }
    @connected_by_external_id = current_user.agendas.google
      .where(external_id: @calendars.pluck(:external_id))
      .index_by(&:external_id)
  end

  # POST /agenda_connection/calendars/connect
  # Connect a single Google calendar: create an Agenda row and kick off
  # an initial sync. Idempotent — re-connecting an already-connected
  # calendar is a no-op + a re-sync.
  def connect_calendar
    external_id = params[:external_id].to_s.presence
    return redirect_to(new_agenda_connection_path, alert: "Missing calendar id.") if external_id.blank?

    agenda = current_user.agendas.find_or_initialize_by(
      source: :google, external_id: external_id,
    )
    agenda.name = params[:name].to_s.presence || agenda.name.presence || "Google Calendar"
    agenda.color = params[:color].to_s.presence || agenda.color.presence || Agenda::DEFAULT_COLOR
    agenda.save!
    ::GoogleCalendarSyncWorker.perform_async(agenda.id)

    redirect_to(
      manage_agenda_path,
      notice: "Connected \"#{agenda.name}\". Events will populate within a minute.",
    )
  end

  # DELETE /agenda_connection/calendars/disconnect
  # Disconnect a single Google calendar: stop its watch channel and
  # destroy the Agenda (cascading items/schedules via dependent: :destroy).
  # OAuth token stays intact so other calendars keep syncing.
  def disconnect_calendar
    external_id = params[:external_id].to_s.presence
    agenda = current_user.agendas.google.find_by(external_id: external_id) if external_id.present?
    return redirect_to(manage_agenda_path, alert: "Calendar not connected.") if agenda.blank?

    name = agenda.name
    ::GoogleCalendar::WatchManager.stop!(agenda) if agenda.watch_channel_id.present?
    agenda.destroy

    redirect_to(manage_agenda_path, notice: "Disconnected \"#{name}\".")
  end

  # DELETE /agenda_connection
  # Disconnect EVERY Google calendar: stops every watch, revokes the OAuth
  # token. `?delete_data=1` also destroys all synced Agenda rows.
  def destroy
    current_user.agendas.google.find_each do |agenda|
      ::GoogleCalendar::WatchManager.stop!(agenda) if agenda.watch_channel_id.present?
    end
    google.revoke!
    current_user.agendas.google.destroy_all if params[:delete_data].to_s == "1"

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
