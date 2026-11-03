module Buddy
  # Everything Buddy changed, newest first, with an undo on each call that can
  # be walked back.
  class ActivitiesController < ApplicationController
    before_action :authorize_user
    before_action :authorize_buddy

    PER_PAGE = 50

    def index
      scope = current_user.buddy_activities.includes(:byte_conversation).recent
      scope = scope.where(byte_conversation_id: params[:conversation_id]) if params[:conversation_id].present?
      scope = scope.where(ok: false) if params[:failed].present?
      scope = scope.where(undone_at: nil).where.not(reverts: []) if params[:undoable].present?
      @activities = scope.page(params[:page]).per(PER_PAGE)
      @conversations = current_user.byte_conversations.where(
        id: current_user.buddy_activities.select(:byte_conversation_id),
      ).order(last_message_at: :desc)
    end

    def undo
      activity = current_user.buddy_activities.find(params[:id])
      summary = activity.undo!
      redirect_back fallback_location: buddy_activities_path, notice: "Undone: #{summary}"
    rescue StandardError => e
      redirect_back fallback_location: buddy_activities_path, alert: "Couldn't undo that: #{e.message}"
    end

    private

    def authorize_buddy
      head :forbidden unless current_user&.byte_access?
    end
  end
end
