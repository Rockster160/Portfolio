class ColorsController < ApplicationController
  def index
    if params[:start_color] || params[:end_color]
      begin
        @colors = ColorGenerator.fade(
          params[:start_color].presence, params[:end_color].presence,
          params[:steps].presence, params[:fade_back].presence == "true"
        )
      rescue ColorGenerationError => e
        @colors = []
        @error = e.message
      end
    else
      @colors = []
    end

    return render partial: "colors", locals: { colors: @colors, error: @error } if request.xhr?

    respond_to do |format|
      format.json {
        render json: @colors.any? ? @colors : { error: @error || "No colors to fade." }
      }
      format.html
    end
  end
end
