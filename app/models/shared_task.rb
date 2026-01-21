# == Schema Information
#
# Table name: shared_tasks
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  task_id    :bigint           not null
#  user_id    :bigint           not null
#
class SharedTask < ApplicationRecord
  belongs_to :task
  belongs_to :user

  validates :task_id, uniqueness: { scope: :user_id }
end
