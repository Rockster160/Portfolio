# == Schema Information
#
# Table name: lists
#
#  id                 :integer          not null, primary key
#  description        :text
#  important          :boolean          default(FALSE)
#  name               :string(255)
#  parameterized_name :text
#  show_deleted       :boolean
#  created_at         :datetime
#  updated_at         :datetime
#

class List < ApplicationRecord
  attr_accessor :do_not_broadcast, :response
  has_many :list_items, dependent: :destroy
  has_many :user_lists, dependent: :destroy
  has_many :users, through: :user_lists

  validates_presence_of :name

  before_save -> { self.parameterized_name = name.parameterize }

  scope :important, -> { where(important: true) }
  scope :unimportant, -> { where.not(important: true) }
  scope :by_param, ->(name) { where(parameterized_name: name.parameterize) }

  def self.by_name_for_user(name, user)
    intro_regexp = /\b(to|for|from|on|in|into)\b/
    my_rx = /\b(the|my)\b/
    list_rx = /\b(list)\b/
    list_intro = name =~ intro_regexp

    found_list = user.ordered_lists.find do |try_list|
      found_msg = name =~ /( #{intro_regexp})?( #{my_rx})?( ?\b#{Regexp.quote(try_list.name.gsub(/[^a-z0-9 ]/i, ""))}\b)( #{list_rx})?/i

      found_msg.present? && found_msg >= 0
    end
  end

  def self.find_and_modify(user, msg)
    return "User not found" if user.blank?

    list = by_name_for_user(msg, user) || user.default_list

    return "List not found" unless list.present?
    intro_regexp = /\b(to|for|from|on|in|into)\b/
    my_rx = /\b(the|my)\b/
    list_rx = /\b(list)\b/
    list_intro = name =~ intro_regexp
    msg = msg.sub(/( #{intro_regexp})?( #{my_rx})? ?#{Regexp.quote(list.name.gsub(/[^a-z0-9 ]/i, ""))}( #{list_rx})?/i, "")
    msg = msg.sub(/ #{my_rx} #{list_rx}/i, "")
    msg = "" if msg.downcase == list.name.downcase

    list.modify_from_message(msg)
  end

  def self.serialize
    all.map(&:serialize)
  end

  def serialize
    {
      id: id,
      name: name,
      description: description,
      important: important,
      show_deleted: show_deleted,
      list_items: ordered_items.pluck(:name),
      response: @response
    }
  end

  def ordered_items
    items = list_items.ordered
    items = items.with_deleted if show_deleted?
    items
  end

  def owner
    user_lists.find_by(is_owner: true).try(:user)
  end

  def owned_by_user?(user)
    !!user_lists.where(user_id: user.try(:id)).first.try(:is_owner?)
  end

  def default_for_user?(user)
    !!user_lists.find_by(user_id: user.try(:id)).try(:default?)
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

  def add(item_name)
    list_items.add(item_name)
  end

  def remove(item_name)
    list_items.remove(item_name)
  end

  def toggle(item_name)
    list_items.toggle(item_name)
  end

  def sort_items!(sort=nil, order=:asc)
    return unless sort.present?
    order = order.to_s.downcase.to_sym
    order = :asc unless order == :desc
    items = case sort.to_s.downcase.to_sym
    when :name
      list_items.with_deleted.order("list_items.name #{order}")
    when :reverse
      list_items.with_deleted.order("list_items.sort_order ASC") # Order is backwards
    when :category
      list_items.with_deleted.order("list_items.category #{order} NULLS LAST")
    when :shuffle
      list_items.with_deleted.order("RANDOM()")
    end

    items&.reverse&.each_with_index do |list_item, idx|
      list_item.update(sort_order: idx, do_not_broadcast: true)
    end
    broadcast!
  end

  def add=(str)
    add(str)
  end

  def remove=(str)
    remove(str)
  end

  def message=(str)
    @response = modify_from_message(str)
  end

  def modify_from_message(msg)
    return "List doesn't exist yet" unless persisted?
    msg = msg.to_s
    response_messages = []
    action, item_names = split_action_and_items_from_msg(msg)

    case action
    when :add
      items = item_names.map do |item_name|
        list_items.by_name_then_update(name: item_name)
      end.select(&:persisted?)
      return "No items added." if items.none?
      return "#{name}:#{ordered_items.map { |item| "\n - #{item.name}" }.join("")}"
    when :remove
      not_destroyed = []
      destroyed_items = []
      item_names.each do |item_name|
        item = list_items.by_formatted_name(item_name)
        next unless item.present?
        if item.soft_destroy
          destroyed_items << item
        else
          not_destroyed << item_name.squish
        end
      end
      response = []

      response << "Could not remove #{not_destroyed.to_sentence} from #{name}." if not_destroyed.any?
      response << "#{name}:#{ordered_items.map { |item| "\n - #{item.name}" }.join("")}"
      response << "<No items>" if ordered_items.none?
      return response.join("\n") if response.any?
    when :clear
      items = list_items.destroy_all
      return "Removed all items from #{name}: \n - #{items.map(&:name).join("\n - ")}"
    else
      if (items = ordered_items).any?
        return "#{name}:#{ordered_items.map { |item| "\n - #{item.name}" }.join("")}"
      else
        return "There are no items in #{name}."
      end
    end
    "Something went wrong."
  end

  def split_action_and_items_from_msg(msg)
    action = ""
    items = []

    msg = msg.gsub("+", " add ").gsub("-", " remove ")
    [:clear, :remove, :add].each do |try_action|
      action = try_action if check_string_starts_word?(msg, try_action)
    end

    msg = msg.sub(/#{action}:?/i, "")
    items = items_from_message(msg)

    [action, items]
  end

  def check_string_contains_word?(sentence, word)
    (sentence =~ regex_for_individual_word(word)).try(:positive?)
  end

  def check_string_starts_word?(sentence, word)
    sentence.gsub(/[^a-zA-Z]/, "").downcase.starts_with?(word.to_s.downcase)
  end

  def regex_for_individual_word(word)
    /\b#{word}\b/
  end

  def items_from_message(msg)
    new_text = msg.dup
    new_text.gsub!(regex_for_individual_word(:add), " ")
    new_text.gsub!(regex_for_individual_word(:remove), " ")
    new_text.gsub!(regex_for_individual_word(:to), " ")
    new_text.gsub!(regex_for_individual_word(:from), " ")
    new_text.gsub!(regex_for_individual_word(:the), " ")
    new_text.split(/\n|,| and /).map { |w| w.squish.presence }.compact
  end

  def fix_list_items_order
    list_items.with_deleted.ordered.each_with_index do |list_item, idx|
      list_item.update(sort_order: idx, do_not_broadcast: true)
    end
  end

  def broadcast!
    return if do_not_broadcast

    ActionCable.server.broadcast "list_#{self.id}_json_channel", { list_data: serialize, timestamp: Time.current.to_i }

    rendered_message = ListsController.render template: "list_items/index", locals: { list: self }, layout: false
    ActionCable.server.broadcast "list_#{self.id}_html_channel", { list_html: rendered_message, timestamp: Time.current.to_i }

    JarvisTriggerWorker.perform_async(:list, { input_vars: { "List Data": serialize } }.to_json, { user: users.ids }.to_json)
  end

end
