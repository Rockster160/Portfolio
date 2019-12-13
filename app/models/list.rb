# == Schema Information
#
# Table name: lists
#
#  id           :integer          not null, primary key
#  name         :string(255)
#  created_at   :datetime
#  updated_at   :datetime
#  description  :text
#  important    :boolean          default(FALSE)
#  show_deleted :boolean
#

class List < ApplicationRecord
  attr_accessor :do_not_broadcast
  has_many :list_items, dependent: :destroy
  has_many :user_lists, dependent: :destroy
  has_many :users, through: :user_lists

  validates_presence_of :name

  scope :important, -> { where(important: true) }
  scope :unimportant, -> { where.not(important: true) }

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

  def ordered_items
    items = list_items.order("list_items.sort_order")
    items = items.with_deleted if show_deleted?
    items
  end

  def owner
    user_lists.find_by(is_owner: true).try(:user)
  end

  def owned_by_user?(user)
    !!user_lists.where(user_id: user.try(:id)).first.try(:is_owner?)
  end

  def collaborators
    users.where(user_lists: { is_owner: [nil, false] })
  end

  def add_items(*item_names)
    [item_names].flatten.map do |item_hash|
      next unless item_hash&.dig(:name).present?

      list_items.by_name_then_update(item_hash)
    end
  end

  def sort_items!(sort=nil, order=:asc)
    return unless sort.present?
    order = order.to_s.downcase.to_sym
    order = :asc unless order == :desc
    items = case sort.to_s.downcase.to_sym
    when :name
      list_items.with_deleted.order("list_items.name #{order}")
    when :category
      list_items.with_deleted.order("list_items.category #{order} NULLS LAST")
    when :shuffle
      list_items.with_deleted.order("RANDOM()")
    end

    items&.each_with_index do |list_item, idx|
      list_item.update(sort_order: idx, do_not_bump_order: true)
    end
    broadcast!
  end

  def message=(str)
    modify_from_message(str)
  end

  def modify_from_message(msg)
    msg = msg.to_s
    response_messages = []
    action, item_names = split_action_and_items_from_msg(msg)

    case action
    when :add
      items = item_names.map do |item_name|
        item = list_items.by_name_then_update(name: item_name)
        puts "#{item.name} - #{item.errors.full_messages}".colorize(:yellow)
        item
      end.select(&:persisted?)
      return "No items added." if items.none?
      return "Running list:\n - #{ordered_items.map(&:name).join("\n - ")}"
    when :remove
      not_destroyed = []
      destroyed_items = []
      item_names.each do |item_name|
        item = list_items.match_by_string(item_name)
        next unless item.present?
        if item.destroy
          destroyed_items << item
        else
          not_destroyed << item_name.squish
        end
      end
      response = []

      response << "Could not remove #{not_destroyed.to_sentence} from #{name}." if not_destroyed.any?
      response << "Removed #{destroyed_items.map(&:name).to_sentence} from #{name}." if destroyed_items.any?
      response << "Running list:\n - #{ordered_items.map(&:name).join("\n - ")}"
      return response.join("\n") if response.any?
    when :clear
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
    action = ""
    items = []

    [:clear, :remove, :add].each do |try_action|
      action = try_action if check_string_starts_word?(msg, try_action)
    end
    return if action == :clear
    msg = msg.sub(/#{action}/i, "")

    items = items_from_message(msg).map(&:squish)
    puts "#{items}".colorize(:red)

    [action, items]
  end

  def check_string_contains_word?(sentence, word)
    (sentence =~ regex_for_individual_word(word)).try(:positive?)
  end

  def check_string_starts_word?(sentence, word)
    sentence.gsub(/[^a-zA-Z]/, "").downcase.starts_with?(word.to_s.downcase)
  end

  def regex_for_individual_word(word)
    /(\W|^)#{word}(\W|$)/i
  end

  def items_from_message(msg)
    new_text = msg.dup
    new_text.gsub!(regex_for_individual_word(:add), " ")
    new_text.gsub!(regex_for_individual_word(:remove), " ")
    new_text.gsub!(regex_for_individual_word(:to), " ")
    new_text.gsub!(regex_for_individual_word(:from), " ")
    new_text.gsub!(regex_for_individual_word(:the), " ")
    new_text.split(/(, *(and)?|and)/).delete_if { |s| s == "and" }
  end

  def fix_list_items_order
    list_items.with_deleted.order(:sort_order).each_with_index do |list_item, idx|
      list_item.update(sort_order: idx, do_not_bump_order: true)
    end
  end

  def broadcast!
    return if do_not_broadcast
    rendered_message = ListsController.render template: "list_items/index", locals: { list: self }, layout: false
    ActionCable.server.broadcast "list_#{self.id}_channel", list_html: rendered_message
  end

end
