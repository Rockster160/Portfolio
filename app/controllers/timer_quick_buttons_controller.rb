class TimerQuickButtonsController < ApplicationController
  before_action :authorize_user
  before_action :set_quick_button, only: [:update, :destroy]

  def index
    render json: current_user.timer_quick_buttons.ordered.map { |q| serialize(q) }
  end

  def create
    qb = current_user.timer_quick_buttons.create!(quick_params)
    render json: serialize(qb), status: :created
  end

  def update
    @qb.update!(quick_params)
    render json: serialize(@qb)
  end

  def destroy
    @qb.destroy
    head :no_content
  end

  # PATCH /timers/quick_buttons/order  body { ids: [3,1,2] }
  def reorder
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render(json: { ok: true }) if ids.empty?

    accessible = current_user.timer_quick_buttons.where(id: ids).pluck(:id)
    return render(json: { ok: true }) if accessible.empty?

    positions = ids.each_with_index.to_h
    case_sql = accessible.map { |qid| "WHEN #{qid.to_i} THEN #{positions[qid].to_i}" }.join(" ")
    TimerQuickButton.where(id: accessible).update_all(
      "sort_order = CASE id #{case_sql} END, updated_at = NOW()",
    )
    render json: { ok: true, count: accessible.size }
  end

  private

  def set_quick_button
    @qb = current_user.timer_quick_buttons.find(params[:id])
  end

  def quick_params
    params.require(:timer_quick_button).permit(
      :label, :duration_seconds, :sort_order, :color, :pinned,
      template: {},
    )
  end

  def serialize(qb)
    {
      id:               qb.id,
      label:            qb.label,
      duration_seconds: qb.duration_seconds,
      sort_order:       qb.sort_order,
      color:            qb.color,
      pinned:           qb.pinned,
      template:         qb.template,
    }
  end
end
