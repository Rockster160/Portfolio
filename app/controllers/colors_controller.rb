class ColorsController < ApplicationController

  def index
    begin
      @colors = ColorGenerator.fade(params[:start_color], params[:end_color], params[:steps], params[:fade_back].present?)
    rescue ColorGenerationError => e
      @colors = []
      @error = e.message
    end

    if request.xhr?
      render partial: "colors", locals: { colors: @colors, error: @error }
    end
  end

end
