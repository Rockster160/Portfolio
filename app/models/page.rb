# == Schema Information
#
# Table name: pages
#
#  id         :bigint           not null, primary key
#  content    :text
#  title      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class Page < ApplicationRecord
  belongs_to :user
end
