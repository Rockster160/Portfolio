# == Schema Information
#
# Table name: contact_tags
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  contact_id :bigint           not null
#  tag_id     :bigint           not null
#
class ContactTag < ApplicationRecord
  belongs_to :tag
  belongs_to :contact
end
