class AgendasController < ApplicationController
  include ExternalAgendaGuard

  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_agenda, only: [:edit, :update, :destroy]
  # Renaming/recoloring/destroying an agenda — including a Google-synced
  # one — requires the :owner role. Editors can manage items inside the
  # agenda but can't change its identity.
  before_action :require_ownership!, only: [:update, :destroy]
  # Externally-managed agendas (Google) can be renamed/recolored by the
  # owner — only destroy is gated (you disconnect via /agenda_connection
  # which also stops the watch + cleans up).
  before_action -> { refuse_external_write!(@agenda) }, only: [:destroy]
  before_action :ensure_default_agenda!, only: [:day, :week, :calendar, :cal_month, :cal_week]

  # JSON accepts `?days=N` (default 1, max 30) to extend the lookahead;
  # week.json uses the same payload shape with days=7.
  def day
    @date = parse_date(params[:date]) || current_user.perceived_today
    @agendas = current_user.accessible_agendas.order(:sort_order, :id)

    respond_to do |format|
      format.json {
        lookahead = (params[:days].presence || 1).to_i.clamp(0, 30)
        render json: aggregate_payload(@date, lookahead: lookahead)
      }
      format.html
    end
  end

  def index
    @agendas = current_user.accessible_agendas.order(:sort_order, :id)
  end

  def week
    @date = parse_date(params[:date]) || current_user.perceived_today
    @agendas = current_user.accessible_agendas.order(:sort_order, :id)
    items = current_user.agenda_items_for_range(@date, @date + 7.days)
    zone = current_user.timezone
    @items_by_date = items.group_by { |i| i.start_at.in_time_zone(zone).to_date }
    @carry_over = current_user.agenda_carry_over_items.to_a

    respond_to do |format|
      format.json { render json: aggregate_payload(@date, lookahead: 7) }
      format.html
    end
  end

  def new
    @agenda = current_user.agendas.new
  end

  def edit; end

  # Optional ?agenda_id query param filters the month to a single agenda.
  def calendar
    @month = parse_month(params[:month]) || current_user.perceived_today.beginning_of_month
    @first_visible = @month.beginning_of_week(:sunday)
    @last_visible = @month.end_of_month.end_of_week(:sunday)

    scope_user = current_user
    scope_agendas = scope_user.accessible_agendas
    if params[:agenda_id].present?
      scope_agendas = scope_agendas.where(id: params[:agenda_id])
    end
    @agendas = scope_agendas.order(:sort_order, :id)

    items = @agendas.flat_map { |a| a.items_for_range(@first_visible, @last_visible) }
    @items_by_date = items.group_by { |item| item.start_at.in_time_zone(scope_user.timezone).to_date }
  end

  # Mac-style Calendar PWA — month view. Same range math as #calendar
  # (full visible weeks) so the grid renders the visible-month block, but
  # no per-day truncation: the JS lays out as many event blocks as fit.
  def cal_month
    @month = parse_month(params[:month]) || current_user.perceived_today.beginning_of_month
    @first_visible = @month.beginning_of_week(cal_week_start_day)
    @last_visible = @month.end_of_month.end_of_week(cal_week_start_day)

    @agendas = current_user.accessible_agendas.order(:sort_order, :id)
    items = @agendas.flat_map { |a| a.items_for_range(@first_visible, @last_visible) }
    @items_by_date = items.group_by { |item| item.start_at.in_time_zone(current_user.timezone).to_date }
    # Title shows whichever month the visible block belongs to (always
    # the requested month for cal_month).
    @focus_date = @month
  end

  # Mac-style Calendar PWA — week time-grid. `?date=YYYY-MM-DD` picks any
  # day in the visible week; the column it lands in is "today" visually
  # only when the user's perceived_today is in the range.
  #
  # NOTE: this action no longer loads items. The view renders a data-
  # free shell; agenda_cal.js hydrates events from AgendaStore (which
  # boots from /agenda/sync/bootstrap + localStorage). Keeping
  # @week_start/@agendas only so the toolbar can render the right title
  # and the add/edit modals' agenda <select>s have their options.
  def cal_week
    @date = parse_date(params[:date]) || current_user.perceived_today
    @week_start = @date.beginning_of_week(cal_week_start_day)
    @week_end = @week_start + 6.days

    @agendas = current_user.accessible_agendas.order(:sort_order, :id)
    today = current_user.perceived_today
    @focus_date = today.between?(@week_start, @week_end) ? today : @week_start
  end

  def create
    @agenda = current_user.agendas.new(agenda_params)
    if @agenda.save
      notif_changed = apply_notification_settings!(@agenda)
      # Notification settings are personal — they have no visible effect
      # on rendered agenda payloads, so we don't broadcast when only those
      # changed. Avoids a refresh-storm for every checkbox toggle.
      @agenda.broadcast! unless notif_changed && !@agenda.previously_new_record?
      respond_to do |format|
        format.json { render json: { id: @agenda.id, slug: @agenda.parameterized_name } }
        format.html { redirect_to manage_agenda_path }
      end
    else
      render json: { errors: @agenda.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return refuse_source_change! if attempt_to_change_source?

    apply_google_rename_color! if @agenda.managed_externally?

    if @agenda.update(agenda_params)
      notif_changed = apply_notification_settings!(@agenda)
      agenda_changed = @agenda.previous_changes.keys.any? { |k| %w[name color sort_order].include?(k) }
      # Only broadcast when the rendered agenda actually changed; pure
      # notification-setting toggles stay quiet.
      @agenda.broadcast! if agenda_changed || !notif_changed
      respond_to do |format|
        format.json { render json: { id: @agenda.id, slug: @agenda.parameterized_name } }
        format.html { redirect_to manage_agenda_path, notice: "Agenda updated." }
      end
    else
      respond_to do |format|
        format.json { render json: { errors: @agenda.errors.full_messages }, status: :unprocessable_entity }
        format.html { render :edit, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @agenda.destroy
    head :no_content
  end

  # Manually enqueue a sync for one Google-synced agenda. Used by the
  # "Retry now" button next to a "Push channel unavailable" badge so the
  # user doesn't have to wait out the 1-day watch-failure cooldown.
  def resync
    @agenda = current_user.agendas.find_by(id: params[:id]) || current_user.agendas.by_param(params[:id]).first
    raise ActionController::RoutingError, "Not Found" if @agenda.blank?
    return head :unprocessable_entity unless @agenda.managed_externally?

    # Reset the failure cooldown so ensure_watch! actually retries.
    @agenda.update!(watch_failed_at: nil)
    ::GoogleCalendarSyncWorker.perform_async(@agenda.id, "manual")
    head :accepted
  end

  def test_push
    ::WebPushNotifications.send_to(
      current_user,
      {
        title: "Notifications are working!",
        body:  "You'll get a buzz like this when your tasks and events come due.",
        icon:  "/agenda_favicon/android-chrome-192x192.png",
        tag:   "agenda-test-push",
        data:  { url: "/agenda" },
      },
      channel: :agenda,
    )
    head :no_content
  end

  private

  def ensure_default_agenda!
    current_user&.ensure_default_agenda
  end

  # First day of the week for the cal PWA. Defaults to :monday to match
  # the Mac Calendar default; future User-level preference goes here so
  # the templates don't need to learn about per-user config.
  def cal_week_start_day
    :monday
  end

  def require_ownership!
    return if @agenda&.owned_by?(current_user)

    head :forbidden
  end

  # Owner-scoped — shared editors can't rename or delete someone else's agenda.
  def set_agenda
    @agenda = current_user.agendas.find_by(id: params[:id]) || current_user.agendas.by_param(params[:id]).first
    raise ActionController::RoutingError, "Not Found" if @agenda.blank?
  end

  def agenda_params
    params.require(:agenda).permit(:name, :color, :sort_order)
  end

  # Source-flipping (user → google or vice versa) is never legitimate via
  # the UI — the FE locks it; this is the BE backstop. An agenda's source
  # is set at create time and stays put for its lifetime.
  def attempt_to_change_source?
    raw = params.dig(:agenda, :source)
    return false if raw.blank?

    raw.to_s != @agenda.source.to_s
  end

  def refuse_source_change!
    respond_to do |format|
      format.json {
        render json: { errors: ["An agenda's source can't be changed after creation."] }, status: :unprocessable_entity
      }
      format.html {
        flash[:alert] = "An agenda's source can't be changed after creation."
        redirect_to(edit_agenda_path(@agenda))
      }
    end
  end

  # Renaming / recoloring a Google-synced agenda used to be a local-only
  # change — diverged silently from Google's view. Now we PATCH the
  # calendar metadata upstream too so the two stay aligned. On API
  # failure we still let the local update proceed and surface a warning
  # in the flash; manual override is sometimes deliberate.
  def apply_google_rename_color!
    return unless @agenda.google_account

    desired_name  = params.dig(:agenda, :name).to_s.presence
    desired_color = params.dig(:agenda, :color).to_s.presence
    body = {}
    body[:summary] = desired_name if desired_name && desired_name != @agenda.name
    body[:backgroundColor] = desired_color if desired_color && desired_color != @agenda.color
    body[:colorRgbFormat] = true if body[:backgroundColor]
    return if body.empty?

    @agenda.google_account.api.patch_calendar(@agenda.external_id, body)
  rescue ::RestClient::Exception => e
    ::Rails.logger.warn("[GoogleCalendar] calendar PATCH failed agenda=#{@agenda.id} #{e.class}: #{e.message}")
    flash.now[:alert] = "Saved locally, but couldn't update Google's copy — check that you own this calendar."
  end

  def notification_setting_params
    raw = params.dig(:agenda, :notification_setting)
    return {} if raw.blank?

    raw.permit(
      :notify_task_oneoff, :notify_task_recurring,
      :notify_event_oneoff, :notify_event_recurring,
      :notify_trigger_oneoff, :notify_trigger_recurring
    ).to_h
  end

  def apply_notification_settings!(agenda)
    attrs = notification_setting_params
    return false if attrs.empty?

    setting = AgendaNotificationSetting.find_or_initialize_by(user: current_user, agenda: agenda)
    setting.assign_attributes(attrs)
    setting.save!
    true
  end

  def aggregate_payload(date, lookahead: 1)
    editable_ids = current_user.editable_agendas.pluck(:id).to_set
    serialize_with_perm = ->(items) {
      items.map { |i| i.serialize.merge(editable: editable_ids.include?(i.agenda_id)) }
    }
    range_items = current_user.agenda_items_for_range(date, date + lookahead.days)
    zone = current_user.timezone
    grouped = range_items.group_by { |i| i.start_at.in_time_zone(zone).to_date }
    days = (0..lookahead).map { |offset|
      d = date + offset.days
      visible = (grouped[d] || []).select { |i| i.visible_on?(d) }
      { date: d.to_s, items: serialize_with_perm.call(visible) }
    }
    {
      date:       date.to_s,
      agendas:    current_user.accessible_agendas.order(:sort_order, :id).map { |a|
        { id: a.id, name: a.name, color: a.color, slug: a.parameterized_name, editable: editable_ids.include?(a.id) }
      },
      days:       days,
      carry_over: serialize_with_perm.call(current_user.agenda_carry_over_items.to_a),
    }
  end

  # Blank-input short-circuit is required: Date.parse is lenient and will
  # interpret an empty/nil string as today rather than raising.
  def parse_date(str)
    return nil if str.blank?

    Date.parse(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_month(str)
    return nil if str.blank?

    Date.parse("#{str}-01").beginning_of_month
  rescue ArgumentError, TypeError
    nil
  end
end
