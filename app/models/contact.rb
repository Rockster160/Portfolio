# == Schema Information
#
# Table name: contacts
#
#  id               :bigint           not null, primary key
#  address          :text
#  lat              :float
#  lng              :float
#  name             :text
#  nickname         :text
#  phone            :text
#  raw              :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  apple_contact_id :text
#  user_id          :bigint
#
class Contact < ApplicationRecord
  belongs_to :user
  has_many :addresses

  serialize :raw, SafeJsonSerializer

  validates_uniqueness_of :apple_contact_id, allow_nil: true

  after_save :store_primary_address

  def primary_address
    addresses.find_by(primary: true) || addresses.first
  end

  def primary_address=(new_address)
    @primary_address = new_address
  end

  def resync
    return if raw.blank?

    json = raw.deep_symbolize_keys

    raw[:addresses]&.each do |raw_address|
      addresses.find_or_create_by(street: raw_address) do |addr|
        addr.user = user
        lat, lng = AddressBook.new(user).loc_from_address(raw_address) || []
        addr.lat = lat
        addr.lng = lng
      end
    end

    update(
      name: json[:name]&.split(" ", 2)&.first, # Should include aliases and allow last names?
      phone: json[:phones]&.first&.dig(:value)&.gsub(/[^\d]/, "")&.last(10),
      nickname: json[:nickname],
    )
  end

  def store_primary_address
    # Basically just used for specs
    addresses.find_or_initialize_by(street: @primary_address[:street]).update(
      primary: true,
      user: user,
      loc: @primary_address[:loc],
    )
  end
end
