class LittleWorldsController < ApplicationController
  include CharacterBuilderHelper
  helper CharacterBuilderHelper

  def show
  end

  def character_builder
    @outfits = CharacterBuilder.default_outfits
    if session[:character_json].present?
      character_json = JSON.parse(session[:character_json])
      @character = CharacterBuilder.new(character_json)
    elsif user_signed_in? && current_user.avatar.present? && current_user.avatar.clothes.any?
      @character = current_user.avatar.character
    else
      @character = CharacterBuilder.new({}, {random: true})
    end
  end

  def change_clothes
    should_random = params[:random].to_s == "true"
    character = CharacterBuilder.new(find_character, {random: should_random})
    current_user.update_avatar(character) if user_signed_in? && params[:save] == "true"
    session[:character_json] = JSON.generate(character.to_json) unless should_random

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  def load_character
    character = get_user_character
    session[:character_json] = JSON.generate(character.to_json)

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  private

  def get_user_character
    current_user.try(:avatar).try(:character) || CharacterBuilder.new({})
  end

  def find_character
    return outfit_from_params if params[:character].present?
    session[:character_json] || get_user_character || {}
  end

  def outfit_from_params
    outfit_from_top_level_hash(params.require(:character).permit!.to_h)
  end

end
