# == Schema Information
#
# Table name: shared_pages
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  page_id    :bigint           not null
#  user_id    :bigint           not null
#
class SharedPage < ApplicationRecord
  belongs_to :page
  belongs_to :user

  validates :page_id, uniqueness: { scope: :user_id }
end
