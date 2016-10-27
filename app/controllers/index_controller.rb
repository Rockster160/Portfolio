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

    reminder_received = false
    LitterTextReminder.all.each do |rem|
      if stripped_text =~ /#{rem.regex}/
        if params["From"] == "+13852599640"
          rem.update(turn: "8019317892")
          reminder_received = true
        elsif params["From"] == "+18019317892"
          rem.update(turn: "3852599640")
          reminder_received = true
        end
      end
    end

    list = List.select { |l| check_string_contains_word?(stripped_text, l.name) || check_string_contains_word?(stripped_text, l.name.split(' ').join('')) }.first || List.first
    if list.present? && !reminder_received
      item_names = items_from_list_text(clean_list_text(stripped_text, [list.name]))
      if check_string_contains_word?(stripped_text, 'add')
        items = item_names.map do |item_name|
          list.list_items.create(name: item_name)
        end
        SmsWorker.perform_async(params["From"], "Added #{items.map(&:name).to_sentence} to #{list.name}.\nRunning list:\n#{list.list_items.map(&:name).join("\n")}") if item.present? && item.persisted?
      elsif check_string_contains_word?(stripped_text, 'remove')
        not_destroyed = []
        destroyed_items = []
        item_names.map do |item_name|
          if (item = list.list_items.where("name ILIKE ?", "%#{item_name}%").first).try(:destroy)
            destroyed_items << item
          else
            not_destroyed << item_name
          end
        end.compact
        sms_messages = []
        if not_destroyed.any?
          sms_messages << "Could not remove #{not_destroyed.to_sentence} from #{list.name}."
        end
        if destroyed_items.any?
          sms_messages << "Removed #{destroyed_items.to_sentence} from #{list.name}."
        end
        SmsWorker.perform_async(params["From"], sms_messages.join("\n")) if sms_message.any?
      elsif check_string_contains_word?(stripped_text, 'clear')
        items = list.list_items.destroy_all
        SmsWorker.perform_async(params["From"], "Removed items from #{list.name}: \n#{items.map(&:name).join("\n")}")
      else
        if (items = list.list_items).any?
          SmsWorker.perform_async(params["From"], "#{list.name.capitalize}: \n#{items.map(&:name).join("\n")}")
        else
          SmsWorker.perform_async(params["From"], "There are no items in #{list.name.capitalize}.")
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
    did_match = (sentence =~ split_from_word_regex(word))
    return false if did_match.nil?
    did_match >= 0
  end

  def split_from_word_regex(word)
    /(\W|^)#{word}(\W|$)/
  end

  def clean_list_text(stripped_text, words_to_clean)
    new_text = stripped_text.dup
    new_text.gsub!(split_from_word_regex('add'), ' ')
    new_text.gsub!(split_from_word_regex('remove'), ' ')
    new_text.gsub!(split_from_word_regex('to'), ' ')
    new_text.gsub!(split_from_word_regex('from'), ' ')
    new_text.gsub!(split_from_word_regex('the'), ' ')
    new_text.gsub!(split_from_word_regex(', and'), ',')
    words_to_clean.each do |word|
      new_text.gsub!(split_from_word_regex(word), ' ')
    end
    new_text.squish
  end

  def items_from_list_text(clean_text)
    clean_text.split(', ')
  end

end
