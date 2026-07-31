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

    private

    def authorize_owner
      head :forbidden unless current_user&.me? || current_user&.chelsea?
    end

    def routine
      @routine ||= current_user.buddy_routines.find(params[:id])
    end

    def routine_params
      params.require(:routine).permit(:name, :description, :enabled)
    end
  end
end
