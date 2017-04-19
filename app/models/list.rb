# == Schema Information
#
# Table name: lists
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  created_at :datetime
#  updated_at :datetime
#

class List < ApplicationRecord
  has_many :list_items

  def self.find_and_modify(msg)
    list = List.first
    List.all.each do |try_list|
      found_msg = msg =~ /#{[Regexp.quote(try_list.name), Regexp.quote(try_list.name.split(" ").join(""))].join("|")}/
      if found_msg.present? && found_msg >= 0
        list = try_list
      end
    end

    list.modify_from_message(msg) if list.present?
  end

  def modify_from_message(msg)
    response_messages = []
    action, item_names = split_action_and_items_from_msg(msg)

    case action
    when 'add'
      items = item_names.map do |item_name|
        self.list_items.create(name: item_name.squish)
      end
      return "Running list:\n#{self.list_items.map(&:name).join("\n")}" if items.any?
    when 'remove'
      not_destroyed = []
      destroyed_items = []
      item_names.map do |item_name|
        if (item = self.list_items.where("name ILIKE ?", "%#{item_name.squish}%").first).try(:destroy)
          destroyed_items << item
        else
          not_destroyed << item_name
        end
      end.compact
      sms_messages = []
      if not_destroyed.any?
        sms_messages << "Could not remove #{not_destroyed.to_sentence} from #{self.name}."
      end
      if destroyed_items.any?
        sms_messages << "Removed #{destroyed_items.map(&:name).to_sentence} from #{self.name}."
      end
      sms_messages << "Running list:\n#{self.list_items.map(&:name).join("\n")}"
      return sms_messages.join("\n") if sms_messages.any?
    when 'clear'
      items = self.list_items.destroy_all
      return "Removed all items from #{self.name}: \n#{items.map(&:name).join("\n")}"
    else
      if (items = self.list_items).any?
        return "#{self.name.titleize}: \n#{items.map(&:name).join("\n")}"
      else
        return "There are no items in #{self.name.capitalize}."
      end
    end
    "Something went wrong."
  end

  def split_action_and_items_from_msg(msg)
    action = ''
    items = []

    ['clear', 'remove', 'add'].each do |try_action|
      action = try_action if check_string_contains_word?(msg, try_action)
    end

    items = items_from_message_after_stripping_action(msg, [self.name])
    puts "#{items}".colorize(:red)

    [action, items]
  end

  def check_string_contains_word?(sentence, word)
    did_match = (sentence =~ regex_for_individual_word(word))
    return false if did_match.nil?
    did_match >= 0
  end

  def regex_for_individual_word(word)
    /(\W|^)#{word}(\W|$)/i
  end

  def items_from_message_after_stripping_action(msg, words_to_clean)
    new_text = msg.dup
    new_text.gsub!(regex_for_individual_word('add'), ' ')
    new_text.gsub!(regex_for_individual_word('remove'), ' ')
    new_text.gsub!(regex_for_individual_word('to'), ' ')
    new_text.gsub!(regex_for_individual_word('from'), ' ')
    new_text.gsub!(regex_for_individual_word('the'), ' ')
    words_to_clean.each do |word|
      new_text.gsub!(regex_for_individual_word(word), ' ')
    end
    new_text.split(/, and\W|,\W?/)
  end

end
