# == Schema Information
#
# Table name: task_folders
#
#  id         :bigint           not null, primary key
#  collapsed  :boolean          default(FALSE)
#  name       :text             not null
#  sort_order :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  parent_id  :bigint
#  user_id    :bigint           not null
#
class TaskFolder < ApplicationRecord
  include Orderable

  belongs_to :user
  belongs_to :parent, class_name: "TaskFolder", optional: true
  has_many :children, class_name: "TaskFolder", foreign_key: :parent_id, dependent: :destroy, inverse_of: :parent
  has_many :tasks, dependent: :nullify

  orderable sort_order: :desc, scope: ->(folder) {
    folder.parent ? folder.parent.children : folder.user.task_folders.where(parent_id: nil)
  }

  validates :name, presence: true

  scope :roots, -> { where(parent_id: nil) }

  def contents
    (children.ordered + tasks.order(sort_order: :desc)).sort_by { |item| -(item.sort_order || 0) }
  end

  def ancestor_ids
    ids = []
    current = parent
    while current
      ids << current.id
      current = current.parent
    end
    ids
  end

  def ancestor_of?(folder)
    folder.ancestor_ids.include?(id)
  end
end
