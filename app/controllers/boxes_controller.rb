class BoxesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    @boxes = current_user.boxes
    # Query needs to be first!
    @boxes = @boxes.query(params[:q]) if params[:q].present?

    # Add option to filter items vs boxes
    @boxes = @boxes.where(empty: true)
    @boxes = @boxes.within(params[:within]) if params[:within].present?

    serialize @boxes
  end

  def show
    @open = current_box.level
    render partial: "inventory_management/box", locals: { box: current_box }
  end

  private

  def current_box
    current_user.boxes.find(params[:id])
  end
end
