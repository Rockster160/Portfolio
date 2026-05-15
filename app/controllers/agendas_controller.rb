class AgendasController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_agenda, only: [:edit, :update, :destroy]
  # The day + calendar views are the user's primary surface — make sure they
  # always have something to render. ensure_default_agenda is idempotent and
  # skips guests / users without a username, so it's safe to call on every
  # request.
  before_action :ensure_default_agenda!, only: [:day, :week, :calendar]

  # GET /agenda — aggregate day view across every accessible agenda.
  # JSON accepts `?days=N` to control lookahead (1 = day view default,
  # 7 = week view). Default date uses perceived_today (3am rollover) so a
  # 1am reload shows "yesterday" — matching the FE's day-key logic.
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

  # GET /agendas — the cards/management page (the only place that lists
  # agendas one-by-one). Pluralization is honest here — this IS the list of
  # agenda entities, not "the agenda."
  def index
    @agendas = current_user.accessible_agendas.order(:sort_order, :id)
  end

  # GET /agenda/week — same layout as #day, extended with seven more
  # preview-styled sections after Tomorrow. An 8-day window (today + 7 ahead)
  # is fetched in one bulk range query rather than per-day, then grouped in
  # memory — no N+1 across the lookahead. JSON delegates to aggregate_payload
  # so day + week share the same fetch-and-apply path on the client.
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

  # Global month view aggregated across accessible agendas. Optional ?agenda_id
  # query param filters to a single agenda for that view only.
  def calendar
    # Default month uses perceived_today (3am rollover), matching day/week.
    # A 1am render on June 1 still treats May 31 as "today," so the calendar
    # shows May and doesn't prematurely flip to June at midnight.
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
        format.html { redirect_to agendas_path }
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
        format.html { redirect_to agendas_path, notice: "Agenda updated." }
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

  private

  def ensure_default_agenda!
    current_user&.ensure_default_agenda
  end

  # Edit/destroy only the agendas the user owns. Shared editors don't get to
  # rename or delete someone else's agenda.
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
    # Bulk-fetch the whole range once, group in memory, then filter per day
    # via visible_on? — same shape day-view and week-view consume.
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

  # Both parsers MUST short-circuit on blank input — Date.parse is famously
  # lenient (e.g. Date.parse("-01") returns today's first-of-month rather
  # than raising), which made `parse_month(nil) || perceived_today.bom`
  # silently use today's calendar month instead of the perceived month.
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
