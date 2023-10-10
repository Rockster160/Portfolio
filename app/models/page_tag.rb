# == Schema Information
#
# Table name: page_tags
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  page_id    :bigint           not null
#  tag_id     :bigint           not null
#
class PageTag < ApplicationRecord
  belongs_to :tag
  belongs_to :page
end
