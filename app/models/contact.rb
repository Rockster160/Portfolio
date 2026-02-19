# == Schema Information
#
# Table name: contacts
#
#  id               :bigint           not null, primary key
#  address          :text
#  data             :jsonb
#  lat              :float
#  lng              :float
#  name             :text
#  nickname         :text
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
  belongs_to :user
  belongs_to :friend, optional: true, class_name: "User"
  has_many :addresses

  search_terms :id, :name, :nickname, :phone

  json_serialize :raw, coder: ::BetterJsonSerializer

  validates :apple_contact_id, uniqueness: { allow_nil: true }

  after_save :store_primary_address

  def self.friends
    joins("LEFT JOIN users AS friends ON friends.id = contacts.friend_id")
  end

  def self.name_find(name)
    name = name.to_s.downcase
    return if name.blank?

    # Exact match (no casing)
    found = find_by("name ILIKE ?", name)
    found ||= find_by("nickname ILIKE ?", name)
    found ||= friends.find_by("friends.username ILIKE ?", name)
    # Exact match without 's and/or house|place
    if found.nil? && name =~ /'?s? ?(house|place)?$/
      found ||= find_by("name ILIKE :name", name: name.gsub(/'?s? ?(house|place)?$/, ""))
      found ||= find_by("nickname ILIKE :name", name: name.gsub(/'?s? ?(house|place)?$/, ""))
      found ||= friends.find_by("friends.username ILIKE :name", name: name.gsub(/'?s? ?(house|place)?$/, ""))
    end
    # Match without special chars
    if found.nil? && name =~ /[^a-z0-9]/
      found ||= find_by("REGEXP_REPLACE(name, '[^ a-z0-9]', '', 'i') ILIKE :name", name: name.gsub(/[^ a-z0-9]/, ""))
      found ||= find_by("REGEXP_REPLACE(nickname, '[^ a-z0-9]', '', 'i') ILIKE :name", name: name.gsub(/[^ a-z0-9]/, ""))
      found ||= friends.find_by("REGEXP_REPLACE(friends.username, '[^ a-z0-9]', '', 'i') ILIKE :name", name: name.gsub(/[^ a-z0-9]/, ""))
    end
    # Match with only letters
    if found.nil? && name =~ /[^a-z]/
      found ||= find_by("REGEXP_REPLACE(name, '[^a-z]', '', 'i') ILIKE :name", name: name.gsub(/[^a-z]/, ""))
      found ||= find_by("REGEXP_REPLACE(nickname, '[^a-z]', '', 'i') ILIKE :name", name: name.gsub(/[^a-z]/, ""))
      found ||= friends.find_by("REGEXP_REPLACE(friends.username, '[^a-z]', '', 'i') ILIKE :name", name: name.gsub(/[^a-z]/, ""))
    end
    found
  end

  def serialize
    {
      id:           id,
      name:         name,
      nickname:     nickname,
      username:     username,
      permit_relay: friend_id.presence && permit_relay,
      phone:        phone,
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
