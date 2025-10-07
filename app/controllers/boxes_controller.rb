class BoxesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def show
    render partial: "inventory_management/box", locals: { box: current_box, preload: true }
  end

  private

  def current_box
    current_user.boxes.find(params[:id])
  end
end
