class AgendaConnectionsController < ApplicationController
  # The agenda controllers all skip CSRF verification — these routes are
  # only reachable from a signed-in user's own buttons.
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  # GET /agenda_connection/start/google
  # Kicks off OAuth. Same path for "first account" and "another account" —
  # Google's prompt=select_account on our auth_url lets the user pick.
  # The callback at /webhooks/oauth/google_api exchanges the code, decodes
  # the id_token email, and creates a GoogleAccount row before redirecting
  # back to #new.
  def start_google
    redirect_to(::Oauth::GoogleApi.new(current_user).auth_url, allow_other_host: true)
  end

  # GET /agenda_connection/new
  #   * No GoogleAccount rows yet → render the "Sign in with Google" CTA.
  #   * One or more → render a section per account showing every calendar
  #     from `users/me/calendarList`, each row marked Connected (Agenda
  #     exists) or with a Connect button. Plus a "Connect another account"
  #     CTA.
  def new
    @accounts = current_user.google_accounts.order(:email)
    if @accounts.empty?
      @needs_auth = true
      return
    end

    @account_sections = @accounts.map { |account| build_section(account) }
  end

  # POST /agenda_connection/calendars/connect
  # Connect a single Google calendar. Scoped by (user, google_account_id,
  # external_id) — a row is identified by which account it came in
  # through, so the same Google calendar surfaced under two different
  # accounts gets two distinct Agendas (matches the user's mental model).
  def connect_calendar
    account = find_account
    return redirect_to(new_agenda_connection_path, alert: "Unknown Google account.") unless account

    external_id = params[:external_id].to_s.presence
    return redirect_to(new_agenda_connection_path, alert: "Missing calendar id.") if external_id.blank?

    agenda = current_user.agendas.find_or_initialize_by(
      source:            :google,
      google_account_id: account.id,
      external_id:       external_id,
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
  # Destroy a single Agenda (cascading items/schedules) + stop its watch.
  # Tokens stay intact so the rest of the account's calendars keep syncing.
  def disconnect_calendar
    account = find_account
    external_id = params[:external_id].to_s.presence
    agenda = (
      if account && external_id
        account.agendas.find_by(external_id: external_id)
      end
    )
    return redirect_to(manage_agenda_path, alert: "Calendar not connected.") if agenda.blank?

    name = agenda.name
    ::GoogleCalendar::WatchManager.stop!(agenda) if agenda.watch_channel_id.present?
    agenda.destroy

    redirect_to(manage_agenda_path, notice: "Disconnected \"#{name}\".")
  end

  # DELETE /agenda_connection
  # Disconnect modes:
  #   * `google_account_id=N` → soft-disconnect that one account: stop
  #     watches, drop agendas, revoke token, mark `disconnected_at`. The
  #     row stays so the picker can re-list it as a Reconnect option.
  #   * no params (Disconnect everything) → full removal: stop watches,
  #     revoke tokens, destroy every GoogleAccount row (cascading agendas).
  #     The user is back to the bare "Sign in with Google" state.
  def destroy
    if params[:google_account_id].present?
      account = current_user.google_accounts.find_by(id: params[:google_account_id])
      soft_disconnect!(account) if account
      return redirect_to(manage_agenda_path, notice: "Google account disconnected.")
    end

    current_user.google_accounts.find_each { |account| purge_account!(account) }
    redirect_to(manage_agenda_path, notice: "Google Calendar disconnected.")
  end

  private

  def soft_disconnect!(account)
    account.agendas.find_each do |agenda|
      ::GoogleCalendar::WatchManager.stop!(agenda) if agenda.watch_channel_id.present?
    end
    account.agendas.destroy_all
    account.api.revoke! rescue nil # best-effort — Google may already have invalidated
    account.update!(
      access_token:    nil,
      refresh_token:   nil,
      id_token:        nil,
      disconnected_at: ::Time.current,
    )
  end

  def purge_account!(account)
    account.agendas.find_each do |agenda|
      ::GoogleCalendar::WatchManager.stop!(agenda) if agenda.watch_channel_id.present?
    end
    account.api.revoke! rescue nil
    account.destroy
  end

  def find_account
    id = params[:google_account_id]
    return nil if id.blank?

    current_user.google_accounts.find_by(id: id)
  end

  # For each account, fetch its CalendarList and join with already-connected
  # Agendas so the view can render Connect/Disconnect per row.
  #   * Soft-disconnected account (no tokens) → return a "reconnect this
  #     account" stub so the picker still lists it.
  #   * Token still alive but Google rejects → flag needs_reauth.
  #   * Otherwise → list every available calendar.
  def build_section(account)
    if account.disconnected_at.present? || account.access_token.blank?
      return {
        account:      account,
        calendars:    [],
        connected:    {},
        load_error:   false,
        needs_reauth: true,
        disconnected: true,
      }
    end

    list = account.api.list_calendars
    calendars = Array(list&.[](:items)).map { |c|
      {
        external_id: c[:id],
        name:        c[:summary],
        color:       c[:backgroundColor],
        primary:     c[:primary] == true,
      }
    }
    connected = account.agendas.where(external_id: calendars.pluck(:external_id)).index_by(&:external_id)
    {
      account:      account,
      calendars:    calendars,
      connected:    connected,
      load_error:   list.blank?,
      needs_reauth: account.reload.needs_reauth?,
      disconnected: false,
    }
  rescue ::RestClient::Exception, ::SocketError => e
    ::Rails.logger.warn("[AgendaConnectionsController] account=#{account.id} #{e.class}: #{e.message}")
    account.mark_reauth_required! unless account.needs_reauth?
    {
      account:      account,
      calendars:    [],
      connected:    {},
      load_error:   true,
      needs_reauth: true,
      disconnected: false,
    }
  end
end
