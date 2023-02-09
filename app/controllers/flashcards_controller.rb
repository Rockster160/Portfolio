class FlashcardsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def flashcard
    @all = FlashCard.all
    @card = FlashCard.find(params[:old].to_i)
    case params[:type]
    when "new" then new_card
    when "edit" then @read_card = false
    when "next" then next_card
    when "back" then back_card
    when "save" then save_card
    when "delete" then delete_card
    else
      @card = FlashCard.first
      @read_card = true
    end
    @read_card = params[:status] == 'true' if params[:status]
    @all = FlashCard.all.sort_by(&:id)
    @card_num = @all.index(@card) + 1
    respond_to do |format|
      format.html
      format.js
    end
  end

  private

  def new_card
    @card = FlashCard.create
    @read_card = false
  end

  def next_card
    binding.pry
    @card = @card.next
    @read_card = true
  end

  def back_card
    @card = @card.previous
    @read_card = true
  end

  def save_card
    line_indices = @card.lines.map(&:id)
    @card.update(title: params[:title], body: params[:body])
    center = params[:center] ? params[:center].map { |should_center_line| should_center_line[0].to_i } : []
    params[:line].each do |line|
      this_line = @card.lines.find(line_indices[line[0].to_i])
      this_line.update(text: line[1], center: center.include?(line[0].to_i))
    end
    @card.reload
    @read_card = true
  end

  def delete_card
    old_card = @card
    next_card
    old_card.destroy
  end

end
