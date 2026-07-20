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

  def print
    @layout = %i[card full].map(&:to_s).include?(params[:layout]) ? params[:layout].to_sym : :card
    slot_count = @layout == :card ? 4 : 1

    raw_slots = params[:slots].to_s.split(",", slot_count).map { |s| s.strip.to_i.nonzero? }
    raw_slots = raw_slots + Array.new(slot_count - raw_slots.length, nil)

    lookup_ids = raw_slots.compact.uniq
    viewable = Recipe.viewable(current_user).where(id: lookup_ids).index_by(&:id)

    @slot_ids = raw_slots.map { |id| id && viewable.key?(id) ? id : nil }
    @slot_recipes = @slot_ids.map { |id| id && viewable[id] }
    @primary = @slot_recipes.compact.first
    @pickable = Recipe.viewable(current_user).order(Arel.sql("LOWER(title)"))

    render layout: "print"
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
      :servings,
      :prep_time,
      :cook_time,
      :ingredients,
      :instructions,
      :notes,
      :public,
    )
  end
end
