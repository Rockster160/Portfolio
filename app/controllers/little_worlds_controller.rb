class LittleWorldsController < ApplicationController

  def show
  end

  def character_builder
    # @outfits = CharacterBuilder.
    if session[:character_json].present?
      character_json = JSON.parse(session[:character_json])
      @character = CharacterBuilder.new(character_json)
    end
  end

  def change_clothes
    should_random = params[:random].to_s == "true"
    character = CharacterBuilder.new(get_character, {random: should_random})
    session[:character_json] = JSON.generate(character.to_json) unless should_random

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  private

  def get_character
    return params.require(:character).permit!.to_h if params[:character].present?
    current_user.try(:character_json) || session[:character_json] || {}
  end

end
