# == Schema Information
#
# Table name: folders
#
#  id                 :bigint           not null, primary key
#  name               :text
#  parameterized_name :text
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  folder_id          :bigint
#  user_id            :bigint
#
class Folder < ApplicationRecord
  include Folderable, Orderable

  belongs_to :folder, optional: true
  belongs_to :user
  has_many :folders
  has_many :pages
  has_many :folder_tags
  has_many :tags, through: :folder_tags

  before_save -> { self.parameterized_name = name.parameterize }
end
