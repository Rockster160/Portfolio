class LittleWorldsController < ApplicationController
  skip_before_action :verify_authenticity_token
  include CharacterBuilderHelper
  helper CharacterBuilderHelper

  def show
    @avatar = find_avatar(session_first: false)
    @character = @avatar.character
    @world = MapGenerator.generate
  end

  def save_location
    @avatar = find_avatar(session_first: false)

    if @avatar.present? && location_params[:timestamp].to_i > @avatar.timestamp.to_i
      @avatar.update(location_params)
      @avatar.broadcast_movement
    end

    head :ok
  end

  def player_login
    @avatar = Avatar.find_by(uuid: params[:uuid])
    @character = @avatar.try(:character) || CharacterBuilder.new(default_outfit)

    render partial: "player", layout: false
  end

  def character_builder
    @outfits = CharacterBuilder.default_outfits
    @character = find_character(session_first: true)
  end

  def change_clothes
    should_random = params[:random].to_s == "true"
    should_save = params[:save] == "true"

    avatar = find_avatar(session_first: !should_save)
    character = avatar.character(random: should_random)
    avatar.update_by_builder(character) if should_save

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  def load_character
    avatar = find_avatar(session_first: false)
    session[:avatar_id] = avatar.id
    character = avatar.character

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  private

  def find_character(session_first:)
    return CharacterBuilder.new(outfit_from_params) if params[:character].present?

    find_avatar(session_first: session_first).try(:character) || CharacterBuilder.new(default_outfit)
  end

  def find_avatar(session_first:)
    if session_first
      avatar = Avatar.find_by(id: session[:avatar_id]) || current_user.try(:avatar)
    else
      avatar = current_user.try(:avatar) || Avatar.find_by(id: session[:avatar_id])
    end

    avatar ||= Avatar.create

    session[:avatar_id] = avatar.id
    avatar
  end

  def outfit_from_params
    outfit_from_top_level_hash(params.require(:character).permit!.to_h)
  end

  def location_params
    params.require(:avatar).permit(:location_x, :location_y, :timestamp)
  end

end
