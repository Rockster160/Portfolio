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
    @card_num = FlashCard.all.index(@card)
  end

  def flashcard
    # binding.pry
    case params[:type]
    when "new"
      @card = FlashCard.new
      @card.save
      @read = false
    when "edit"
      @card = FlashCard.find(params[:old].to_i)
      @read = false
    when "save"
      FlashCard.find(params[:old].to_i).save
      @card = FlashCard.find(params[:old].to_i)
      @read = true
    when "delete"
      FlashCard.find(params[:old].to_i).destroy
      @card = FlashCard.all.last
      @read = true
    else
      @card = FlashCard.find(0)
      @read = true
    end
      @card_num = FlashCard.all.index(@card)
    respond_to do |format|
      format.html
      format.js
    end
  end
end
