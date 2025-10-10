class RecipesController < ApplicationController
  before_action :authorize_user_or_guest, :set_recipe
  before_action :authorize_owner, only: [:edit, :update, :destroy]

  def index
    @recipes = Recipe.viewable(current_user).order(:created_at)
  end

  def show
  end

  def new
    @recipe = current_user.recipes.new

    render :form
  end

  def edit
    render :form
  end

  def create
    @recipe = current_user.recipes.new(recipe_params)

    if @recipe.save
      redirect_to @recipe
    else
      render :form
    end
  end

  def update
    if @recipe.update(recipe_params)
      redirect_to @recipe
    else
      render :form
    end
  end

  def destroy
    if @recipe.destroy
      redirect_to recipes_path
    else
      redirect_to @recipe,
        alert: "Failed to delete recipe: #{@recipe.errors.full_messages.join("\n")}"
    end
  end

  def export_to_list
    list = List.find(params[:list_id])

    if @recipe.export_to_list(list)
      redirect_to @recipe, notice: "All items added to list."
    else
      redirect_to @recipe, alert: "Failed to export."
    end
  end

  private

  def authorize_owner
    return if @recipe.user == current_user

    redirect_to @recipe, alert: "You cannot make changes to this recipe."
  end

  def set_recipe
    if params[:friendly_id].present?
      @recipe = Recipe.find_by(friendly_url: params[:friendly_id])
      @recipe ||= Recipe.find(params[:friendly_id])
    end
  end

  def recipe_params
    params.require(:recipe).permit(
      :title,
      :description,
      :kitchen_of,
      :ingredients,
      :instructions,
      :public,
    )
  end
end
