# == Schema Information
#
# Table name: pages
#
#  id                 :bigint           not null, primary key
#  content            :text
#  name               :string
#  parameterized_name :text
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  folder_id          :bigint
#  user_id            :bigint           not null
#
class Page < ApplicationRecord
  include Orderable
  include Folderable

  belongs_to :folder, optional: true
  belongs_to :user
  has_many :page_tags
  has_many :tags, through: :page_tags

  before_save -> { self.parameterized_name = name.parameterize }
end
