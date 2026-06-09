class TimersController < ApplicationController
  before_action :authorize_user
  before_action :set_timer, only: [:update, :destroy, :start, :pause, :resume, :reset, :confirm, :increment, :advance, :layout]

  DEFAULT_QUICK_DURATIONS = [60, 120, 180, 300, 600, 900, 1800].freeze

  # GET /timers
  def index
    @active_view = :inbox
    @active_page = nil
    load_page_data
    render :page
  end

  # GET /timers/page/:slug
  def page
    @active_view = :page
    @active_page = current_user.timer_pages.find_by!(slug: params[:slug])
    load_page_data
    render :page
  end

  # GET /timers/sync?since=<iso>
  def sync
    since_ts = parse_iso(params[:since])

    timers_scope = current_user.timers.unscope(where: :archived_at)
    pages_scope  = current_user.timer_pages
    quick_scope  = current_user.timer_quick_buttons

    if since_ts
      timers_scope = timers_scope.where(updated_at: since_ts..)
      pages_scope  = pages_scope.where(updated_at: since_ts..)
      quick_scope  = quick_scope.where(updated_at: since_ts..)
    end

    archived_ids = current_user.timers
      .unscope(where: :archived_at)
      .where.not(archived_at: nil)
    archived_ids = archived_ids.where(archived_at: since_ts..) if since_ts

    render json: {
      server_ts:     Time.current.iso8601(3),
      timers:        timers_scope.live.map { |t| TimerSerializer.new(t, viewer: current_user).as_json },
      pages:         pages_scope.map { |p| serialize_page(p) },
      quick_buttons: quick_scope.ordered.map { |q| serialize_quick(q) },
      archived_ids:  archived_ids.pluck(:id),
    }
  end

  # GET /timers/csrf
  def csrf
    render json: { token: form_authenticity_token, server_ts: Time.current.iso8601(3) }
  end

  # POST /timers/items
  #
  # Supports a no-JS happy path: when `start_immediately=1` is sent (the
  # server-rendered quick buttons use this), the timer is created AND
  # started in the same request, then we redirect back to /timers so the
  # next page load shows the timer already running. JSON callers get the
  # same data in the response body, no redirect.
  def create
    timer = current_user.timers.build(timer_params)
    timer.save!
    timer.start! if start_immediately? && timer.countdown?
    @timer = timer
    broadcast_timer(:created)

    respond_to do |format|
      format.html { redirect_to(timer.timer_page&.slug ? timer_page_path(slug: timer.timer_page.slug) : timers_path) }
      format.json { render json: timer_payload(timer), status: :created }
    end
  end

  # PATCH /timers/items/:id
  def update
    @timer.update!(timer_params)
    if @timer.countdown? && @timer.running?
      @timer.reschedule_fire!
      # Mid-countdown triggers depend on the current callback set + end_at.
      # An edit could add/remove/reword countdown_at callbacks while the
      # timer is mid-run; we replay the schedule so the Sidekiq queue
      # reflects what the user just saved.
      @timer.reschedule_countdown_callbacks!
    end
    broadcast_timer(:updated)
    render json: timer_payload(@timer)
  end

  # Hard delete — `destroy` and not soft-archive. A deleted timer must
  # never resurrect from sync/bootstrap, never fire callbacks at its
  # scheduled end_at, and never leave orphan share tokens behind. The
  # `cancel_fire!` removes the Sidekiq scheduled job; `destroy` (with
  # the model's `dependent: :destroy` association) drops the row AND its
  # share tokens; the worker's `find_by(id: ...)` early-returns when it
  # eventually pops off the queue and finds nothing.
  def destroy
    @timer.cancel_fire!
    timer_id = @timer.id
    @timer.destroy
    broadcast(reason: :destroyed, timer_id: timer_id, deleted: true)
    render json: { archived_id: timer_id, server_ts: Time.current.iso8601(3) }
  end

  def start
    @timer.start!
    broadcast_timer(:started)
    render json: timer_payload(@timer)
  end

  def pause
    @timer.pause!
    broadcast_timer(:paused)
    render json: timer_payload(@timer)
  end

  def resume
    @timer.resume!
    broadcast_timer(:resumed)
    render json: timer_payload(@timer)
  end

  def reset
    @timer.reset!
    broadcast_timer(:reset)
    render json: timer_payload(@timer)
  end

  def confirm
    @timer.confirm!
    @timer.reload
    broadcast_timer(:confirmed)
    render json: timer_payload(@timer)
  end

  def increment
    @timer.apply_increment!(by: params[:by].to_i.nonzero? || 1)
    @timer.reload
    broadcast_timer(:incremented)
    render json: timer_payload(@timer)
  end

  # `reload` after the dial advance — nested chains can mutate the
  # row we're holding via separate AR instances (e.g. Swarm wraps,
  # fires sCb3 which advances Phase, which lands on Swarm step, which
  # fires pCb2 enabling Swarm — all on copies of self). Without the
  # reload, the controller's broadcast + JSON response carry self's
  # pre-chain in-memory state and the FE applies that stale view on
  # top of the (correct) chain broadcast.
  def advance
    @timer.advance_dial!(by: params[:by].to_i.nonzero? || 1)
    @timer.reload
    broadcast_timer(:advanced)
    render json: timer_payload(@timer)
  end

  def layout
    @timer.update!(layout_params)
    broadcast_timer(:layout_changed)
    render json: timer_payload(@timer)
  end

  # PATCH /timers/order — body { ids: [...] }
  def reorder
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render(json: { ok: true }) if ids.empty?

    accessible_ids = current_user.timers.where(id: ids).pluck(:id)
    return render(json: { ok: true }) if accessible_ids.empty?

    positions = ids.each_with_index.to_h
    case_sql = accessible_ids.map { |tid| "WHEN #{tid.to_i} THEN #{positions[tid].to_i}" }.join(" ")
    Timer.where(id: accessible_ids).update_all(
      "pos_y = CASE id #{case_sql} END, updated_at = NOW()",
    )

    broadcast(reason: :reordered, ids: accessible_ids)
    render json: { ok: true, count: accessible_ids.size }
  end

  private

  def load_page_data
    @timers = current_user.timers.ordered.to_a
    @pages  = current_user.timer_pages.ordered.to_a
    # Always seed user defaults so Home has something to show; then
    # ensure the current page (if any) has its own copy. Quick buttons
    # are sent in full to the FE; the renderer filters by active page.
    ensure_default_quick_buttons!
    ensure_page_quick_buttons!(@active_page) if @active_page
    @quick_buttons = current_user.timer_quick_buttons.ordered.to_a

    @bootstrap = {
      server_ts:           Time.current.iso8601(3),
      user_id:             current_user.id,
      active_view:         @active_view,
      active_page_slug:    @active_page&.slug,
      pages:               @pages.map { |p| serialize_page(p) },
      timers:              @timers.map { |t| TimerSerializer.new(t, viewer: current_user).as_json },
      quick_buttons:       @quick_buttons.map { |q| serialize_quick(q) },
      active_share_tokens: serialize_share_tokens,
    }
  end

  def ensure_default_quick_buttons!
    return if current_user.timer_quick_buttons.user_defaults.exists?

    DEFAULT_QUICK_DURATIONS.each_with_index do |secs, idx|
      current_user.timer_quick_buttons.create!(duration_seconds: secs, sort_order: idx)
    end
  end

  # Duplicates the user's PINNED defaults onto a TimerPage the first
  # time it's viewed. Saved templates (pinned=false) stay global and are
  # never copied — they live as user defaults and are visible from any
  # page's Saved tab.
  #
  # Concurrency: a freshly-created page can be hit by several requests
  # back-to-back (browser nav + SW shell warm + monitor reconnect),
  # which is how I'd see 4× seeding before. `with_lock` serializes them
  # on the row, the inner `reload` picks up any commit the winner
  # already made, and `meta["quicks_seeded"]` is the durable marker so
  # subsequent requests skip without even taking the lock.
  def ensure_page_quick_buttons!(page)
    return if page.meta.is_a?(Hash) && page.meta["quicks_seeded"]

    page.with_lock do
      page.reload
      return if page.meta.is_a?(Hash) && page.meta["quicks_seeded"]
      return if page.quick_buttons.exists?

      current_user.timer_quick_buttons.user_defaults.where(pinned: true).ordered.each do |src|
        page.quick_buttons.create!(
          user:             current_user,
          label:            src.label,
          duration_seconds: src.duration_seconds,
          sort_order:       src.sort_order,
          color:            src.color,
          pinned:           true,
          template:         src.template || {},
        )
      end
      page.merge_meta!(quicks_seeded: true)
    end
  end

  def serialize_page(page)
    {
      id:          page.id,
      slug:        page.slug,
      name:        page.name,
      layout_mode: page.layout_mode,
      sections:    page.sections,
      sort_order:  page.sort_order,
      meta:        page.meta || {},
      buttons:     page.page_buttons.ordered.map { |b| serialize_page_button(b) },
      updated_at:  page.updated_at.iso8601(3),
    }
  end

  def serialize_page_button(btn)
    {
      id:         btn.id,
      label:      btn.label,
      color:      btn.color,
      target_url: btn.target_url,
      sort_order: btn.sort_order,
      updated_at: btn.updated_at.iso8601(3),
    }
  end

  def serialize_quick(qb)
    {
      id:               qb.id,
      label:            qb.label,
      duration_seconds: qb.duration_seconds,
      sort_order:       qb.sort_order,
      color:            qb.color,
      pinned:           qb.pinned,
      template:         qb.template,
      timer_page_id:    qb.timer_page_id,
      updated_at:       qb.updated_at.iso8601(3),
    }
  end

  def serialize_share_tokens
    current_user.timer_share_tokens.live.map { |s|
      {
        id:            s.id,
        token:         s.token,
        timer_id:      s.timer_id,
        timer_page_id: s.timer_page_id,
        access_mode:   s.access_mode,
        url:           "/t/#{s.token}",
      }
    }
  end

  def set_timer
    @timer = current_user.timers.unscope(where: :archived_at).find(params[:id])
  end

  def timer_payload(timer)
    {
      timer:     TimerSerializer.new(timer, viewer: current_user).as_json,
      server_ts: Time.current.iso8601(3),
    }
  end

  def broadcast(**data)
    MonitorChannel.broadcast_to(current_user, {
      id:        :timers,
      channel:   :timers,
      timestamp: Time.current.to_i,
      data:      data.merge(
        actor_user_id: current_user.id,
        actor_tab_id:  params[:tab_id],
        server_ts:     Time.current.iso8601(3),
      ),
    })
  end

  # Broadcast carrying the updated timer's serialized state inline.
  # Receivers can `upsertTimer` directly without a follow-up /sync GET —
  # guarantees cross-tab state propagation even if the receiver's
  # `lastSyncTs` is out of step with the server clock.
  def broadcast_timer(reason)
    broadcast(
      reason:    reason,
      timer_id:  @timer.id,
      timer:     TimerSerializer.new(@timer, viewer: current_user).as_json,
    )
  end

  def timer_params
    permitted = params.require(:timer).permit(
      :name, :kind, :color, :timer_page_id, :section_id,
      :pos_x, :pos_y, :width, :height, :disabled,
      :duration_ms, :repeat,
      :value, :step, :min_value, :max_value, :reset_value,
      # callbacks have a free-form `when` and `then` hash each — the
      # union of accepted keys grows as new trigger / action types are
      # added, so we permit the whole sub-hash via to_unsafe_h below.
      callbacks: [:id],
    )
    # callbacks store a free-form (when, then) pair per row. The set of
    # keys grows as new trigger / action types are added so we lift the
    # raw arrays directly off params and to_unsafe_h them. Values are
    # jsonb-only — no SQL, no HTML, nothing rendered un-escaped.
    raw_callbacks = params.dig(:timer, :callbacks)
    if raw_callbacks.is_a?(ActionController::Parameters) || raw_callbacks.is_a?(Array)
      arr = raw_callbacks.respond_to?(:to_unsafe_h) ? raw_callbacks.to_unsafe_h.values : Array(raw_callbacks)
      permitted[:callbacks] = arr.map do |cb|
        cb.respond_to?(:to_unsafe_h) ? cb.to_unsafe_h : cb.to_h
      end
    end

    # dial_config is free-form JSON (sections array of hashes, each with
    # a subs array of strings). Strong params' `dial_config: {}` form
    # permits an arbitrary hash, but to avoid any chance of nested-array
    # filtering on edge cases we explicitly to_unsafe_h here — the field
    # is jsonb, no SQL/HTML risk.
    raw_dial = params.dig(:timer, :dial_config)
    case raw_dial
    when ActionController::Parameters then permitted[:dial_config] = raw_dial.to_unsafe_h
    when Hash then permitted[:dial_config] = raw_dial
    end
    permitted
  end

  def layout_params
    params.require(:timer).permit(:pos_x, :pos_y, :width, :height, :section_id, :timer_page_id)
  end

  def start_immediately?
    ActiveModel::Type::Boolean.new.cast(params[:start_immediately])
  end

  def parse_iso(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
