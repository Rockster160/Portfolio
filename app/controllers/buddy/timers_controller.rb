module Buddy
  # Buddy hero timer chips: hydrate the live list, and pause / resume / cancel /
  # acknowledge from a tap or swipe. Delegates the actual lifecycle to the Timer
  # model (server-authoritative), then broadcasts so every open surface stays in
  # sync. Scoped to the person's OWN Buddy timers - never another page's.
  class TimersController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    # Initial hydrate for the hero on page load / reconnect. A board asks with
    # its id and gets only the timers placed on it.
    def index
      board = ByteConversation.accessible_boards_for(current_user).find_by(id: params[:board_id]) if params[:board_id]
      timers = board ? Buddy::Timers.live_for_board(board) : Buddy::Timers.live_for(current_user)
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
      Buddy::Timers.stop!(timer)
      head :no_content
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end

    # Only Buddy's timers are reachable here - a regular timer id 404s. A
    # household member's is reachable once it's placed on a board, so the
    # screen showing it can pause, cancel or acknowledge it.
    def timer
      @timer ||= Buddy::Timers.reachable(current_user, params[:id]) || raise(ActiveRecord::RecordNotFound)
    end

    def serialize(timer)
      TimerSerializer.new(timer, viewer: current_user).as_json
    end
  end
end
