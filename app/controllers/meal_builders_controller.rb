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
  end

  def create
    @meal_builder = current_user.meal_builders.new(meal_builder_params)

    if @meal_builder.save
      redirect_to @meal_builder, notice: "Meal builder was successfully created."
    else
      render :new
    end
  end

  def edit
  end

  def update
    if @meal_builder.update(meal_builder_params)
      redirect_to @meal_builder, notice: "Meal builder was successfully updated."
    else
      render :edit
    end
  end

  def destroy
    @meal_builder.destroy
    redirect_to meal_builders_path, notice: "Meal builder was successfully deleted."
  end

  private

  def set_meal_builder
    @meal_builder = current_user.meal_builders.find_by!(parameterized_name: params[:id])
  end

  def meal_builder_params
    params.require(:meal_builder).permit(:name, :items)
  end
end
