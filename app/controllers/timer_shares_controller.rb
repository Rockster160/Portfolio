class TimerSharesController < ApplicationController
  ALLOWED_ACTIONS = %w[start pause resume reset confirm increment advance].freeze

  before_action :authorize_user, only: [:create, :update, :destroy]
  skip_before_action :verify_authenticity_token, only: [:act]
  before_action :set_share, only: [:update, :destroy]
  before_action :load_public_share, only: [:show, :sync, :act]

  # ---------------------------------------------------------------
  # Public (recipient) — token-scoped read + interactive actions.
  # ---------------------------------------------------------------

  def show
    @share.increment!(:hit_count)
    @bootstrap = build_share_bootstrap
    render layout: "application"
  end
  # ---------------------------------------------------------------
  # Private (owner) — CRUD a share token for a timer or page.
  # ---------------------------------------------------------------

  def create
    target_attrs = share_params
    share = current_user.timer_share_tokens.new(target_attrs)
    share.save!
    render json: serialize(share), status: :created
  end

  def update
    @share.update!(share_params.slice(:access_mode, :expires_at))
    render json: serialize(@share)
  end

  def destroy
    @share.revoke!
    render json: { id: @share.id, revoked_at: @share.revoked_at.iso8601(3) }
  end

  def sync
    render json: build_share_bootstrap.merge(server_ts: Time.current.iso8601(3))
  end

  def act
    return head(:forbidden) unless @share.interactive?

    target_action = params[:action_kind].to_s
    target_action = params[:action].to_s if target_action.blank?
    return head(:bad_request) unless ALLOWED_ACTIONS.include?(target_action)

    timer = resolve_share_timer(params[:timer_id])
    return head(:not_found) unless timer

    apply_share_action!(timer, target_action)
    render json: { timer: TimerSerializer.new(timer, viewer: @share.user, share: @share).as_json, server_ts: Time.current.iso8601(3) }
  end

  private

  def set_share
    @share = current_user.timer_share_tokens.find(params[:id])
  end

  def load_public_share
    @share = TimerShareToken.find_by(token: params[:token])
    if @share.nil? || !@share.usable?
      render plain: "Share link is no longer available.", status: :gone
      return
    end
  end

  def share_params
    params.require(:timer_share_token).permit(:timer_id, :timer_page_id, :access_mode, :expires_at)
  end

  def serialize(share)
    {
      id:            share.id,
      token:         share.token,
      timer_id:      share.timer_id,
      timer_page_id: share.timer_page_id,
      access_mode:   share.access_mode,
      expires_at:    share.expires_at&.iso8601(3),
      revoked_at:    share.revoked_at&.iso8601(3),
      hit_count:     share.hit_count,
      url:           "/t/#{share.token}",
    }
  end

  def build_share_bootstrap
    case @share.target
    when Timer
      {
        share_mode: @share.access_mode,
        token:      @share.token,
        timers:     [TimerSerializer.new(@share.target, viewer: @share.user, share: @share).as_json],
        page:       nil,
      }
    when TimerPage
      page = @share.target
      {
        share_mode: @share.access_mode,
        token:      @share.token,
        timers:     page.timers.ordered.map { |t| TimerSerializer.new(t, viewer: @share.user, share: @share).as_json },
        page:       {
          id:          page.id,
          slug:        page.slug,
          name:        page.name,
          layout_mode: page.layout_mode,
          sections:    page.sections,
        },
      }
    end
  end

  def resolve_share_timer(requested_id)
    case @share.target
    when Timer
      return @share.target if requested_id.blank? || requested_id.to_i == @share.target.id

      nil
    when TimerPage
      @share.target.timers.find_by(id: requested_id)
    end
  end

  def apply_share_action!(timer, target_action)
    case target_action
    when "start"     then timer.start!
    when "pause"     then timer.pause!
    when "resume"    then timer.resume!
    when "reset"     then timer.reset!
    when "confirm"   then timer.confirm!
    when "increment" then timer.apply_increment!(by: params[:by].to_i.nonzero? || 1)
    when "advance"   then timer.advance_dial!(by: params[:by].to_i.nonzero? || 1)
    end
  end
end
