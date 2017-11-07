# == Schema Information
#
# Table name: lists
#
#  id          :integer          not null, primary key
#  name        :string(255)
#  created_at  :datetime
#  updated_at  :datetime
#  description :text
#

class List < ApplicationRecord

  has_many :list_items, dependent: :destroy
  has_many :user_lists, dependent: :destroy
  has_many :users, through: :user_lists

  validates_presence_of :name

  def self.find_and_modify(msg)
    list = first
    List.all.each do |try_list|
      found_msg = msg =~ /#{[Regexp.quote(try_list.name), Regexp.quote(try_list.name.split(" ").join(""))].join("|")}/
      if found_msg.present? && found_msg >= 0
        list = try_list
      end
    end

    list.modify_from_message(msg) if list.present?
  end

  def owned_by_user?(user)
    !!user_lists.where(user_id: user.try(:id)).first.try(:is_owner?)
  end

  def modify_from_message(msg)
    msg = msg.to_s
    response_messages = []
    action, item_names = split_action_and_items_from_msg(msg)

    case action
    when 'add'
      items = item_names.map do |item_name|
        item = list_items.create(name: item_name.squish)
        puts "#{item.name} - #{item.errors.full_messages}".colorize(:yellow)
        item
      end.select(&:persisted?)
      return "No items added." if items.none?
      return "Running list:\n - #{list_items.map(&:name).join("\n - ")}"
    when 'remove'
      not_destroyed = []
      destroyed_items = []
      item_names.map do |item_name|
        if (item = list_items.match_by_string(item_name)).try(:destroy)
          destroyed_items << item
        else
          not_destroyed << item_name.squish
        end
      end
      sms_messages = []
      if not_destroyed.any?
        sms_messages << "Could not remove #{not_destroyed.to_sentence} from #{name}."
      end
      if destroyed_items.any?
        sms_messages << "Removed #{destroyed_items.map(&:name).to_sentence} from #{name}."
      end
      sms_messages << "Running list:\n - #{list_items.map(&:name).join("\n - ")}"
      return sms_messages.join("\n") if sms_messages.any?
    when 'clear'
      items = list_items.destroy_all
      return "Removed all items from #{name}: \n - #{items.map(&:name).join("\n - ")}"
    else
      if (items = list_items).any?
        return "#{name.titleize}: \n - #{items.map(&:name).join("\n - ")}"
      else
        return "There are no items in #{name.capitalize}."
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

    items = items_from_message_after_stripping_action(msg, [name]).map(&:squish)
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

  def fix_list_items_order
    list_items.order(:sort_order).each_with_index do |list_item, idx|
      list_item.update(sort_order: idx, do_not_bump_order: true)
    end
  end

  def broadcast!
    rendered_message = ListsController.render template: "list_items/index", locals: { list: self }, layout: false
    ActionCable.server.broadcast "list_#{self.id}_channel", list_html: rendered_message
  end

  def jsonify
    attributes.symbolize_keys.slice(:id, :name, :description).merge(list_items: list_items.ordered.map(&:jsonify))
  end

end
