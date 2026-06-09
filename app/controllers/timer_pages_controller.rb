class TimerPagesController < ApplicationController
  before_action :authorize_user
  before_action :set_page, only: [:update, :destroy]

  def create
    page = current_user.timer_pages.build(page_params)
    page.slug = page_params[:slug].presence || page.name.to_s.parameterize.presence || SecureRandom.hex(4)
    page.save!
    broadcast(reason: :page_created, page_id: page.id)
    render json: serialize(page), status: :created
  end

  def update
    @page.update!(page_params)
    broadcast(reason: :page_updated, page_id: @page.id)
    render json: serialize(@page)
  end

  def destroy
    @page.destroy
    broadcast(reason: :page_destroyed, page_id: @page.id)
    head :no_content
  end

  private

  def set_page
    @page = current_user.timer_pages.find(params[:id])
  end

  def page_params
    permitted = params.require(:timer_page).permit(
      :name, :slug, :sort_order, :layout_mode,
      sections: [[:id, :title, :h, :scroll_x]],
    )
    raw_meta = params.dig(:timer_page, :meta)
    case raw_meta
    when ActionController::Parameters then permitted[:meta] = raw_meta.to_unsafe_h
    when Hash                         then permitted[:meta] = raw_meta
    end
    permitted
  end

  def serialize(page)
    {
      id:          page.id,
      name:        page.name,
      slug:        page.slug,
      layout_mode: page.layout_mode,
      sections:    page.sections,
      sort_order:  page.sort_order,
      meta:        page.meta || {},
      buttons:     page.page_buttons.ordered.map { |b|
        { id: b.id, label: b.label, color: b.color, target_url: b.target_url, sort_order: b.sort_order, updated_at: b.updated_at.iso8601(3) }
      },
      updated_at:  page.updated_at.iso8601(3),
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
