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
    case params[:type]
    when "new"
      @card = FlashCard.new
      @read = false
    when ""
    else
      @card = FlashCard.find(1)
      @read = true
    end
    respond_to do |format|
      format.html
      format.js
    end
  end
end
