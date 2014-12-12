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
      center = []
      line_index = []
      old_flashcard.lines.each do |index|
        line_index << index.id
      end
      if params[:center]
        params[:center].each do |on|
          center << on[0].to_i
        end
      end
      params[:line].each do |line|
        this_index = line_index[line[0].to_i]
        old_flashcard.lines.find(this_index).update_attribute(:text, line[1])
        if center.include?(line[0].to_i)
          old_flashcard.lines.find(this_index).update_attribute(:center, true)
        else
          old_flashcard.lines.find(this_index).update_attribute(:center, false)
        end
      end
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
      status = params[:status]
      if status == "true"
        @read = true
      else
        @read = false
      end
    end
    @card_num = FlashCard.all.index(@card) + 1
    respond_to do |format|
      format.html
      format.js
    end
  end
end
