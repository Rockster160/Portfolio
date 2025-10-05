class InventoryManagementController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  # before_action :set_inventory, only: [:show, :edit, :update, :destroy]

  layout "quick_actions"

  def index
    # @inventories = current_user.inventories.order(created_at: :desc)
  end

  def show
    @boxes = current_user.boxes.where(parent_id: nil).order(:sort_order)
  end

  def new
    # @inventory = current_user.inventories.new
    # render :form
  end

  def edit
    # render :form
  end

  def create
    # @inventory = current_user.inventories.new(inventory_params)

    # if @inventory.save
    #   redirect_to @inventory
    # else
    #   render :form
    # end
  end

  def update
    # if @inventory.update(inventory_params)
    #   respond_to do |format|
    #     format.html { redirect_to @inventory }
    #     format.json { render json: @inventory, status: :ok }
    #   end
    # else
    #   render :edit
    # end
  end

  def destroy
    # @inventory.destroy
    # redirect_to inventories_path
  end

  private

  def set_inventory
    # @inventory = current_user.inventories.find_by!(parameterized_name: params[:id])
  end

  def inventory_params
    # params.require(:inventory).permit(:name).tap do |whitelisted|
    #   if params[:inventory][:items].is_a?(String)
    #     whitelisted[:items] = params[:inventory][:items]
    #   else
    #     whitelisted[:items] = params[:inventory][:items].map(&:permit!)
    #   end
    # end
  end
end
