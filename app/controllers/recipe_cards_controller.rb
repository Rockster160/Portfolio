class RecipeCardsController < ApplicationController
  before_action :set_recipe
  def index
    @recipes = RecipeCard.order(:created_at)
  end

  def show
  end

  def new
    @recipe = current_user.recipe_cards.new

    render :form
  end

  def create
    @recipe = current_user.recipe_cards.new(recipe_params)

    if @recipe.save
      redirect_to @recipe
    else
      render :form
    end
  end

  def edit
    render :form
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
      redirect_to recipe_cards_path
    else
      redirect_to @recipe, alert: "Failed to delete recipe: #{@recipe.errors.full_messages.join("\n")}"
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

  def set_recipe
    @recipe = RecipeCard.find(params[:id]) if params[:id].present?
  end

  def recipe_params
    params.require(:recipe_card).permit(
      :title,
      :kitchen_of,
      :ingredients,
      :instructions,
      :public
    )
  end
end
