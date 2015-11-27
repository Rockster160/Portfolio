class IndexController < ApplicationController
  def home
  end

  def play
    @read = true
    @card = FlashCard.first
    # @card_num = FlashCard.all.index(@card) + 1 if @cards.many?
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
      # @card = all[rand(all.length)] if params[:shuffle] #Won't work because params only pass through form submission. Would have to add in an extra parameter.
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
      old_flashcard.update_attribute(:title, params[:title])
      if params[:center]
        params[:center].each do |on|
          center << on[0].to_i
        end
      end
      params[:line].each do |line|
        this_line = old_flashcard.lines.find(line_index[line[0].to_i])
        this_line.update_attribute(:text, line[1])
        if center.include?(line[0].to_i)
          this_line.update_attribute(:center, true)
        else
          this_line.update_attribute(:center, false)
        end
      end
      old_flashcard.update_attribute(:body, params[:body])
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
