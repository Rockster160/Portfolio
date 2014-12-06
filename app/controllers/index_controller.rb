class IndexController < ApplicationController
  def home
  end

  def play
    @read = true
    @cards = FlashCard.all
    @card = FlashCard.find(1)
    @card_num = FlashCard.all.index(@card) + 1
  end

  def flashcard
    all = FlashCard.all
    old_flashcard = FlashCard.find(params[:old].to_i)
    old_index = FlashCard.all.index(old_flashcard)
    case params[:type]
    when "new"
      @card = FlashCard.new
      @card.save
      @read = false
    when "edit"
      @card = old_flashcard
      @read = false
    when "next"
      if old_index == all.length - 1
        back = 0
      else
        back = old_index + 1
      end
      binding.pry
      @card = all[back]
      @read = true
    when "back"
      if old_index == 0
        back = all.length - 1
      else
        back = old_index - 1
      end
      @card = all[back]
      @read = true
    when "save"
      old_flashcard.save
      @card = old_flashcard
      @read = true
    when "delete"
      old_flashcard.destroy
      @card = FlashCard.all.last
    else
      @card = FlashCard.find(0)
      @read = true
    end
    if params[:status]
      @read = params[:status]
    end
    @card_num = FlashCard.all.index(@card) + 1
    respond_to do |format|
      format.html
      format.js
    end
  end
end
