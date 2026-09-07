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

  # POST /timers/pages/:id/duplicate
  #
  # A page IS the template. Build the scoreboard once, copy it for the
  # next game: counters come across at their reset value and countdowns
  # come across unstarted, so the copy is a fresh board rather than a
  # snapshot of one mid-play.
  def duplicate
    source = current_user.timer_pages.find(params[:id])
    copy = nil

    TimerPage.transaction do
      copy = current_user.timer_pages.create!(
        name:        params[:name].presence || "#{source.name.presence || source.slug} copy",
        slug:        next_free_slug(source.slug),
        layout_mode: source.layout_mode,
        sections:    source.sections,
        sort_order:  source.sort_order,
        meta:        source.meta || {},
      )
      copy_timers!(source, copy)
      copy_buttons!(source, copy)
    end

    broadcast(reason: :page_created, page_id: copy.id)
    render json: serialize(copy), status: :created
  end

  private

  # Copies every live timer onto `copy`, then rewrites any chain callback
  # that pointed at a timer on the SOURCE page to its clone. Without the
  # rewrite, a duplicated board's chains keep driving the original's
  # timers — the copy looks right and moves the wrong cards. Chains
  # pointing off-page are left alone; those targets weren't copied.
  def copy_timers!(source, copy)
    id_map = {}
    source.timers.live.ordered.each do |timer|
      clone = current_user.timers.create!(
        timer.attributes.symbolize_keys.slice(
          :name, :kind, :color, :pos_x, :pos_y, :width, :height, :disabled,
          :duration_ms, :repeat, :require_confirm_tap,
          :step, :min_value, :max_value, :reset_value,
          :dial_config, :callbacks, :metadata
        ).merge(timer_page_id: copy.id, value: timer.reset_value),
      )
      id_map[timer.id] = clone.id
    end

    copy.timers.reload.each do |clone|
      rewritten = Array(clone.callbacks).map { |cb|
        target = cb.is_a?(Hash) ? cb.dig("then", "target_timer_id") : nil
        next cb unless target && id_map.key?(target.to_i)

        cb.deep_dup.tap { |c| c["then"]["target_timer_id"] = id_map[target.to_i] }
      }
      clone.update!(callbacks: rewritten) if rewritten != Array(clone.callbacks)
    end
  end

  def copy_buttons!(source, copy)
    source.quick_buttons.ordered.each do |qb|
      copy.quick_buttons.create!(
        user:             current_user,
        label:            qb.label,
        duration_seconds: qb.duration_seconds,
        sort_order:       qb.sort_order,
        color:            qb.color,
        pinned:           qb.pinned,
        template:         qb.template || {},
      )
    end
    source.page_buttons.ordered.each do |btn|
      copy.page_buttons.create!(
        label: btn.label, color: btn.color, target_url: btn.target_url, sort_order: btn.sort_order,
      )
    end
  end

  # "scores" → "scores-2" → "scores-3". Slugs are unique per user and the
  # slug IS the URL, so a copy needs its own rather than a random suffix.
  def next_free_slug(base)
    stem = base.to_s.sub(/-\d+\z/, "").presence || SecureRandom.hex(4)
    taken = current_user.timer_pages.where("slug LIKE ?", "#{stem}%").pluck(:slug).to_set
    (2..).each { |n| return "#{stem}-#{n}" unless taken.include?("#{stem}-#{n}") }
  end

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
