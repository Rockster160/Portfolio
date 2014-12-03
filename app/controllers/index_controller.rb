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
  end

  def flashcard
    @card = FlashCard.find(1)
    respond_to do |format|
      format.html
      format.js
    end
  end
end
