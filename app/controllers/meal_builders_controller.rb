class MealBuildersController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_meal_builder, only: [:show, :edit, :update, :destroy]

  layout "quick_actions", only: [:show]

  def index
    @meal_builders = current_user.meal_builders.order(created_at: :desc)
  end

  def show
  end

  def new
    @meal_builder = current_user.meal_builders.new
    render :form
  end

  def create
    @meal_builder = current_user.meal_builders.new(meal_builder_params)

    if @meal_builder.save
      redirect_to @meal_builder
    else
      render :form
    end
  end

  def edit
    render :form
  end

  def update
    if @meal_builder.update(meal_builder_params)
      respond_to do |format|
        format.html { redirect_to @meal_builder }
        format.json { render json: @meal_builder, status: :ok }
      end
    else
      render :edit
    end
  end

  def destroy
    @meal_builder.destroy
    redirect_to meal_builders_path
  end

  private

  def set_meal_builder
    @meal_builder = current_user.meal_builders.find_by!(parameterized_name: params[:id])
  end

  def meal_builder_params
    params.require(:meal_builder).permit(:name).tap do |whitelisted|
      if params[:meal_builder][:items].is_a?(String)
        whitelisted[:items] = params[:meal_builder][:items]
      else
        whitelisted[:items] = params[:meal_builder][:items].map(&:permit!)
      end
    end
  end
end
