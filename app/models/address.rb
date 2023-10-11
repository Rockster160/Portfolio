# == Schema Information
#
# Table name: addresses
#
#  id         :bigint           not null, primary key
#  icon       :text
#  label      :text
#  lat        :float
#  lng        :float
#  primary    :boolean
#  street     :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  contact_id :bigint
#  user_id    :bigint
#
class Address < ApplicationRecord
  belongs_to :user
  belongs_to :contact

  before_save :set_primary
  after_destroy { contact.addresses.first&.update(primary: true) if primary? }

  def loc
    [lat, lng]
  end

  def lat=(val)
    return super(nil) if val.to_i == 0
    super(val)
  end

  def lng=(val)
    return super(nil) if val.to_i == 0
    super(val)
  end

  def loc=(*new_loc)
    new_lat, new_lng = *Array.wrap(new_loc).flatten
    self.lat = new_lat
    self.lng = new_lng
  end

  private

  def set_primary
    if changed&.include?("primary")
      if primary
        contact.addresses.where(primary: true).where.not(id: id).update_all(primary: false)
      else
        contact.addresses.where.not(id: id).first&.update(primary: true) || self.primary = true
      end
    end
  end
end
