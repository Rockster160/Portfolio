class IndexController < ApplicationController
  def home
  end

  def play
    @read = true
    @cards = FlashCard.all
    if params[:pass_id]
      @card = FlashCard.find(params[:pass_id].to_i)
    else
      @card = FlashCard.find(0)
    end
    respond_to do |format|
      format.html
      format.js { render :partial => "flashcard", :locals => {:card => FlashCard.find(pass_id), :is_read => @read} }
      # format.json { render json: FlashCard.find(pass_id).to_json }
    end
  end

  def flashcard
  end
end
