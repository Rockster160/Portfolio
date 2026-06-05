class TimerPageButtonsController < ApplicationController
  before_action :authorize_user
  before_action :set_page
  before_action :set_button, only: [:update, :destroy]

  def create
    btn = @page.page_buttons.create!(button_params)
    broadcast(reason: :page_button_changed, timer_page_id: @page.id)
    render json: serialize(btn), status: :created
  end

  def update
    @btn.update!(button_params)
    broadcast(reason: :page_button_changed, timer_page_id: @page.id)
    render json: serialize(@btn)
  end

  def destroy
    @btn.destroy
    broadcast(reason: :page_button_changed, timer_page_id: @page.id)
    head :no_content
  end

  private

  def set_page
    @page = current_user.timer_pages.find(params[:timer_page_id])
  end

  def set_button
    @btn = @page.page_buttons.find(params[:id])
  end

  def button_params
    params.require(:button).permit(:label, :color, :target_url, :sort_order)
  end

  def serialize(btn)
    {
      id:         btn.id,
      label:      btn.label,
      color:      btn.color,
      target_url: btn.target_url,
      sort_order: btn.sort_order,
      updated_at: btn.updated_at.iso8601(3),
    }
  end

  def broadcast(**data)
    MonitorChannel.broadcast_to(current_user, {
      id:        :timers,
      channel:   :timers,
      timestamp: Time.current.to_i,
      data:      data.merge(actor_tab_id: params[:tab_id], server_ts: Time.current.iso8601(3)),
    })
  end
end
