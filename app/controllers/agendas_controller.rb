class AgendasController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_agenda, only: [:edit, :update, :destroy]
  before_action :ensure_default_agenda!, only: [:day, :week, :calendar]

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

  def create
    @agenda = current_user.agendas.new(agenda_params)
    if @agenda.save
      @agenda.broadcast!
      respond_to do |format|
        format.json { render json: { id: @agenda.id, slug: @agenda.parameterized_name } }
        format.html { redirect_to manage_agenda_path }
      end
    else
      render json: { errors: @agenda.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @agenda.update(agenda_params)
      @agenda.broadcast!
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

  # Owner-scoped — shared editors can't rename or delete someone else's agenda.
  def set_agenda
    @agenda = current_user.agendas.find_by(id: params[:id]) || current_user.agendas.by_param(params[:id]).first
    raise ActionController::RoutingError, "Not Found" if @agenda.blank?
  end

  def agenda_params
    params.require(:agenda).permit(:name, :color, :sort_order)
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
