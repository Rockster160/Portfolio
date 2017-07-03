class LittleWorldsController < ApplicationController

  def show
  end

  def character_builder
  end

  def change_clothes
    character = CharacterBuilder.new((params[:character] || {}).to_hash)

    respond_to { |format| format.json { render json: { json: character.to_json, html: character.to_html } } }
  end

end
