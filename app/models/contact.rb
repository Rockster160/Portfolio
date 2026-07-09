# == Schema Information
#
# Table name: contacts
#
#  id               :bigint           not null, primary key
#  address          :text
#  birthday         :date
#  data             :jsonb
#  email            :text
#  lat              :float
#  lng              :float
#  name             :text
#  nickname         :text
#  notes            :text
#  permit_relay     :boolean          default(TRUE)
#  phone            :text
#  raw              :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  apple_contact_id :text
#  friend_id        :bigint
#  user_id          :bigint
#
class Contact < ApplicationRecord
  include Taggable

  belongs_to :user
  belongs_to :friend, optional: true, class_name: "User"
  has_many :addresses
  has_many :contact_tags
  has_many :tags, through: :contact_tags

  search_terms :id, :name, :nickname, :phone, :email

  json_serialize :raw, coder: ::BetterJsonSerializer

  validates :apple_contact_id, uniqueness: { allow_nil: true }

  after_save :store_primary_address

  def self.friends
    joins("LEFT JOIN users AS friends ON friends.id = contacts.friend_id")
  end

  # nickname is a comma-separated list; each token is a valid alias.
  NICKNAME_TOKENS_SQL = "regexp_split_to_array(LOWER(nickname), '\\s*,\\s*')".freeze

  def self.name_find(name)
    name = name.to_s.downcase
    return if name.blank?

    # Exact match (no casing)
    found = find_by("name ILIKE ?", name)
    found ||= find_by("? = ANY(#{NICKNAME_TOKENS_SQL})", name)
    found ||= friends.find_by("friends.username ILIKE ?", name)
    # Exact match without 's and/or house|place
    if found.nil? && name =~ /'?s? ?(house|place)?$/
      trimmed = name.gsub(/'?s? ?(house|place)?$/, "")
      found ||= find_by("name ILIKE ?", trimmed)
      found ||= find_by("? = ANY(#{NICKNAME_TOKENS_SQL})", trimmed)
      found ||= friends.find_by("friends.username ILIKE ?", trimmed)
    end
    # Match without special chars
    if found.nil? && name =~ /[^a-z0-9]/
      stripped = name.gsub(/[^ a-z0-9]/, "")
      found ||= find_by("REGEXP_REPLACE(name, '[^ a-z0-9]', '', 'i') ILIKE ?", stripped)
      found ||= find_by(nickname_token_regexp_sql("[^ a-z0-9]"), stripped)
      found ||= friends.find_by("REGEXP_REPLACE(friends.username, '[^ a-z0-9]', '', 'i') ILIKE ?", stripped)
    end
    # Match with only letters
    if found.nil? && name =~ /[^a-z]/
      stripped = name.gsub(/[^a-z]/, "")
      found ||= find_by("REGEXP_REPLACE(name, '[^a-z]', '', 'i') ILIKE ?", stripped)
      found ||= find_by(nickname_token_regexp_sql("[^a-z]"), stripped)
      found ||= friends.find_by("REGEXP_REPLACE(friends.username, '[^a-z]', '', 'i') ILIKE ?", stripped)
    end
    found
  end

  def self.nickname_token_regexp_sql(strip_pattern)
    "EXISTS (SELECT 1 FROM unnest(#{NICKNAME_TOKENS_SQL}) AS nick " \
      "WHERE REGEXP_REPLACE(nick, '#{strip_pattern}', '', 'g') = ?)"
  end

  def serialize
    {
      id:           id,
      name:         name,
      nickname:     nickname,
      username:     username,
      permit_relay: friend_id.presence && permit_relay,
      phone:        phone,
      email:        email,
      birthday:     birthday,
      notes:        notes,
      tags:         tags.map(&:name),
      data:         data,
    }
  end

  def primary_address
    addresses.find_by(primary: true) || addresses.first
  end

  attr_writer :primary_address

  def friend?
    friend_id?
  end

  def username
    friend&.username
  end

  def username=(new_username)
    self.friend_id = User.find_by(username: new_username)&.id
  end

  def resync
    return if raw.blank?

    json = raw.deep_symbolize_keys

    raw[:addresses]&.each do |raw_address|
      addresses.find_or_create_by(street: raw_address) { |addr|
        addr.user = user
        lat, lng = AddressBook.new(user).loc_from_address(raw_address) || []
        addr.lat = lat
        addr.lng = lng
      }
    end

    update(
      name:     json[:name]&.split(" ", 2)&.first, # Should include aliases and allow last names?
      phone:    json[:phones]&.first&.dig(:value)&.gsub(/[^\d]/, "")&.last(10),
      email:    json[:emails]&.first&.dig(:value),
      nickname: json[:nickname],
    )
  end

  def store_primary_address
    return if @primary_address.blank?

    # Basically just used for specs
    addresses.find_or_initialize_by(street: @primary_address[:street]).update(
      primary: true,
      user:    user,
      loc:     @primary_address[:loc],
    )
  end
end
