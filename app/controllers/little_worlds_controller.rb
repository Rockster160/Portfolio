class LittleWorldsController < ApplicationController
  skip_before_action :verify_authenticity_token
  include CharacterBuilderHelper
  helper CharacterBuilderHelper

  def show
    @avatar = current_user.try(:avatar)
    @character = find_character(session_first: false)
    @world = MapGenerator.generate
  end

  def save_location
    @avatar = current_user.try(:avatar)
    @avatar.update(location_params) if @avatar.present? && location_params[:timestamp].to_i > @avatar.timestamp.to_i

    head :ok
  end

  def player_login
    @avatar = Avatar.by_uuid(params[:uuid])
    @character = @avatar.try(:character) || CharacterBuilder.new(default_outfit)

    render partial: "player", layout: false
  end

  def character_builder
    @outfits = CharacterBuilder.default_outfits
    @character = find_character(session_first: true)
  end

  def change_clothes
    should_random = params[:random].to_s == "true"
    character = find_character(session_first: true, options: { random: should_random })
    current_user.update_avatar(character) if user_signed_in? && params[:save] == "true"
    session[:character_json] = JSON.generate(character.to_json) unless should_random

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  def load_character
    character = find_character(session_first: false)
    session[:character_json] = JSON.generate(character.to_json)

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  private

  def find_character(session_first:, options:{})
    return CharacterBuilder.new(outfit_from_params, options) if params[:character].present?
    if session_first
      return CharacterBuilder.new(session_character_json, options) if session_character_json
      return current_user.avatar.character if current_user.try(:avatar).try(:clothes).try(:any?)
    else
      return current_user.avatar.character if current_user.try(:avatar).try(:clothes).try(:any?)
      return CharacterBuilder.new(session_character_json, options) if session_character_json
    end
    CharacterBuilder.new(default_outfit, options)
  end

  def session_character_json
    JSON.parse(session[:character_json]) if session[:character_json]
  end

  def outfit_from_params
    outfit_from_top_level_hash(params.require(:character).permit!.to_h)
  end

  def default_outfit
    {
      gender: "male",
      body: "light",
      clothing: {
        torso: { garment: "leather", color: "chest"},
        legs: { garment: "pants", color: "teal"},
        feet: { garment: "shoes", color: "black"}
      }
    }
  end

  def location_params
    params.require(:avatar).permit(:location_x, :location_y, :timestamp)
  end

end
