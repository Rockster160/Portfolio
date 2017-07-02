class LittleWorldsController < ApplicationController

  def show
  end

  def character_builder
  end

  def change_clothes
    character = CharacterBuilder.build_character_from_clothing_params(params[:clothing])
    character_html = CharacterBuilder.html_for_character_obj(character)

    respond_to { |format| format.html { render json: { json: character, html: character_html } } }
  end

end
