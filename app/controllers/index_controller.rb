class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token

  def home
  end

  def play
    @read_card = true
    @card = FlashCard.first
    @card_num = FlashCard.all.index(@card) + 1 if FlashCard.all.many?
  end

  def talk
    is_me = params["From"] == "+13852599640"

    stripped_text = params["Body"].downcase.gsub(/[^a-z0-9\s]/i, '')

    LitterTextReminder.all.each do |rem|
      if stripped_text =~ /#{rem.regex}/
        if params["From"] == "+13852599640"
          rem.update(turn: "8019317892")
        elsif params["From"] == "+18019317892"
          rem.update(turn: "3852599640")
        end
      end
    end

    List.all.each do |list|
      if check_string_contains_word?(stripped_text, list.name)
        if check_string_contains_word?(stripped_text, 'add')
          item = list.list_items.create(name: clean_list_text(stripped_text, [list.name]))
          SmsWorker.perform_async(params["From"], "Added #{item.name} to #{list.name}.") if item.present? && item.persisted?
        elsif check_string_contains_word?(stripped_text, 'remove')
          item = list.list_items.where(name: "%#{clean_list_text(stripped_text, [list.name])}%").first.try(:destroy)
          SmsWorker.perform_async(params["From"], "Removed #{item.name} from #{list.name}.") if item.present? && item.destroyed?
        elsif check_string_contains_word?(stripped_text, 'clear')
          items = list.list_items.destroy_all
          SmsWorker.perform_async(params["From"], "Removed items from #{list.name}: \n#{items.map(&:name).join("\n")}")
        else
          SmsWorker.perform_async(params["From"], "The running list for #{list.name} is: \n#{list.list_items.map(&:name).join("\n")}")
        end
      end
    end

    head :ok
  end

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

  def check_string_contains_word?(sentence, word)
    (sentence =~ split_from_word_regex(word)) >= 0
  end

  def split_from_word_regex(word)
    /(\W|^)#{word}(\W|$)/
  end

  def clean_list_text(stripped_text, words_to_clean)
    stripped_text.gsub!(split_from_word_regex('add'), ' ')
    stripped_text.gsub!(split_from_word_regex('remove'), ' ')
    stripped_text.gsub!(split_from_word_regex('to'), ' ')
    words_to_clean.each do |word|
      stripped_text.gsub!(split_from_word_regex(word), ' ')
    end
    stripped_text.squish
  end

end
