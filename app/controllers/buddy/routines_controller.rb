module Buddy
  # The routines panel in the Byte drawer: see what's saved, rename one, turn
  # one off, delete one. Creating and editing STEPS happens by talking to Byte
  # (`save_routine`), because the steps are tool calls with validated arguments
  # and a text box is a poor way to write those - so this deliberately doesn't
  # take `steps`.
  class RoutinesController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    def index
      render json: { routines: current_user.buddy_routines.ordered.map(&:serialize_for_client) }
    end

    def update
      if routine.update(routine_params)
        render json: routine.serialize_for_client
      else
        render json: { errors: routine.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      routine.destroy!
      head :no_content
    end

    # Tap on the Quick grid. Runs deterministically with no model turn - see
    # Buddy::Routines.run! - so it costs nothing and does the same thing twice.
    def run
      return render(json: { error: "that routine is turned off" }, status: :unprocessable_entity) unless routine.enabled?

      conversation = current_user.byte_conversations.buddy.active.find_by(id: params[:conversation_id])
      return render(json: { error: "conversation not found" }, status: :not_found) if conversation.nil?

      Buddy::Routines.run!(routine, conversation: conversation)
      render json: routine.serialize_for_client
    end

    # Whole-grid reorder in one request. The client sends the pinned ids in the
    # order it just dropped them into, and every position is rewritten from that
    # - a per-row PATCH would leave the grid half-reordered if one of them
    # failed, and the order is a single fact rather than N independent ones.
    #
    # Anything omitted is unpinned, so this is also how the last one comes off
    # the grid.
    def reorder
      ids = Array(params[:ids]).map(&:to_i).uniq.select(&:positive?)
      mine = current_user.buddy_routines.where(id: ids).index_by(&:id)

      # Validation is skipped deliberately. `steps_are_runnable` re-checks every
      # step against the live tool registry, which is right when the steps
      # change and pure cost when only a grid position does — and it would let a
      # routine that has gone stale block a reorder that has nothing to do with
      # it.
      BuddyRoutine.transaction {
        # rubocop:disable Rails/SkipsModelValidations
        current_user.buddy_routines.pinned.where.not(id: ids).update_all(position: nil)
        ids.each_with_index { |id, i| mine[id]&.update_column(:position, i) }
        # rubocop:enable Rails/SkipsModelValidations
      }

      render json: { routines: current_user.buddy_routines.ordered.map(&:serialize_for_client) }
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.me? || current_user&.chelsea?
    end

    def routine
      @routine ||= current_user.buddy_routines.find(params[:id])
    end

    # Deliberately no `position`: the grid's order is one fact, so #reorder owns
    # it outright. Pinning is that list plus one, unpinning is it minus one.
    def routine_params
      params.require(:routine).permit(:name, :description, :enabled)
    end
  end
end
