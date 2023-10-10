# == Schema Information
#
# Table name: folder_tags
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  folder_id  :bigint
#  tag_id     :bigint
#
class FolderTag < ApplicationRecord
  belongs_to :folder
  belongs_to :tag
end
