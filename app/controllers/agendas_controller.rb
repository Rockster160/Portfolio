class AgendasController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_agenda, only: [:edit, :update, :destroy]

  # GET /agenda — aggregate day view across every accessible agenda.
  def day
    @date = parse_date(params[:date]) || Date.current
    @agendas = current_user.accessible_agendas.order(:sort_order, :id)

    respond_to do |format|
      format.json { render json: aggregate_payload(@date) }
      format.html
    end
  end

  # GET /agendas — the cards/management page (the only place that lists
  # agendas one-by-one). Pluralization is honest here — this IS the list of
  # agenda entities, not "the agenda."
  def index
    @agendas = current_user.accessible_agendas.order(:sort_order, :id)
  end

  def new
    @agenda = current_user.agendas.new
  end

  def edit; end

  # Global month view aggregated across accessible agendas. Optional ?agenda_id
  # query param filters to a single agenda for that view only.
  def calendar
    @month = parse_month(params[:month]) || Date.current.beginning_of_month
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
      render json: { id: @agenda.id, slug: @agenda.parameterized_name }
    else
      render json: { errors: @agenda.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @agenda.destroy
    head :no_content
  end

  private

  # Edit/destroy only the agendas the user owns. Shared editors don't get to
  # rename or delete someone else's agenda.
  def set_agenda
    @agenda = current_user.agendas.find_by(id: params[:id]) || current_user.agendas.by_param(params[:id]).first
    raise ActionController::RoutingError, "Not Found" if @agenda.blank?
  end

  def agenda_params
    params.require(:agenda).permit(:name, :color, :sort_order)
  end

  def aggregate_payload(date)
    {
      date:       date.to_s,
      agendas:    current_user.accessible_agendas.order(:sort_order, :id).map { |a|
        { id: a.id, name: a.name, color: a.color, slug: a.parameterized_name }
      },
      today:      current_user.agenda_visible_items_for(date).map(&:serialize),
      tomorrow:   current_user.agenda_visible_items_for(date + 1).map(&:serialize),
      carry_over: current_user.agenda_carry_over_items.map(&:serialize),
    }
  end

  def parse_date(str)
    Date.parse(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_month(str)
    Date.parse("#{str}-01").beginning_of_month
  rescue ArgumentError, TypeError
    nil
  end
end
