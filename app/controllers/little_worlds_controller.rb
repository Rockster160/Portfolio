class LittleWorldsController < ApplicationController
  skip_before_action :verify_authenticity_token
  include CharacterBuilderHelper
  helper CharacterBuilderHelper

  def show
    @logged_in_users = Avatar.logged_in
    @avatar = find_avatar(session_first: false)
    @character = @avatar.character
    @world = MapGenerator.generate
    cookies.signed[:avatar_uuid] = @avatar.uuid
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
    @character = @avatar.try(:character) || Avatar.default_character

    render partial: "player", layout: false
  end

  def character_builder
    @outfits = CharacterBuilder.default_outfits
    @character = find_avatar(session_first: true).character
    flash.now[:notice] = "Avatar from session loaded. Click 'Load' in order to load your saved Avatar." if user_signed_in?
  end

  def change_clothes
    should_random = params[:random].to_s == "true"
    should_save = params[:save] == "true"

    session_avatar = find_avatar(session_first: true)
    character = if should_random
      session_avatar.character(random: should_random)
    elsif params[:character].present?
      CharacterBuilder.new(outfit_from_params)
    else
      Avatar.default_character
    end

    session_avatar.update_by_builder(character)
    current_user.avatar.update_by_builder(character) if should_save

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  def load_character
    avatar = find_avatar(session_first: false)
    character = avatar.character

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

  private

  def find_avatar(session_first:)
    if session_first
      avatar = Avatar.from_session.find_by(id: session[:avatar_id]) || Avatar.create
      avatar.update(from_session: true, user_id: nil) unless avatar.from_session
      session[:avatar_id] = avatar.id
    elsif user_signed_in?
      avatar = current_user.try(:avatar) || Avatar.create(user_id: current_user.id)
      session_avatar = find_avatar(session_first: true)
    else
      avatar = find_avatar(session_first: true)
    end

    avatar
  end

  def outfit_from_params
    outfit_from_top_level_hash(params.require(:character).permit!.to_h)
  end

  def location_params
    params.require(:avatar).permit(:location_x, :location_y, :timestamp)
  end

end
