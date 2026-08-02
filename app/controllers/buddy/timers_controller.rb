module Buddy
  # Buddy hero timer chips: hydrate the live list, and pause / resume / cancel /
  # acknowledge from a tap or swipe. Delegates the actual lifecycle to the Timer
  # model (server-authoritative), then broadcasts so every open surface stays in
  # sync. Scoped to the person's OWN Buddy timers - never another page's.
  class TimersController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    # Initial hydrate for the hero on page load / reconnect.
    def index
      timers = Buddy::Timers.live_for(current_user)
      render json: {
        page_id: Buddy::Timers.page_for(current_user).id,
        timers:  timers.map { |t| TimerSerializer.new(t, viewer: current_user).as_json },
      }
    end

    def pause
      timer.pause!
      timer.broadcast(reason: :paused)
      render json: serialize(timer)
    end

    def resume
      timer.resume!
      timer.broadcast(reason: :resumed)
      render json: serialize(timer)
    end

    # The person acknowledged an alarm (tapped the fired chip / the page). Clears
    # the fired state so the chip drops out of the alarming treatment.
    def confirm
      timer.confirm!
      render json: serialize(timer)
    end

    # Swipe-away = archive. Cancels the pending fire + mid-countdown jobs, then
    # broadcasts a removal so the chip disappears everywhere.
    def destroy
      timer.cancel_fire!
      timer.cancel_countdown_callbacks!
      timer.update!(archived_at: Time.current)
      timer.broadcast(reason: :archived)
      head :no_content
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end

    # Only Buddy's own timers are reachable here - a regular board timer id 404s.
    def timer
      @timer ||= (
        found = current_user.timers.unscope(where: :archived_at).find_by(id: params[:id])
        raise ActiveRecord::RecordNotFound if found.nil? || !Buddy::Timers.buddy_timer?(current_user, found)

        found
      )
    end

    def serialize(timer)
      TimerSerializer.new(timer, viewer: current_user).as_json
    end
  end
end
