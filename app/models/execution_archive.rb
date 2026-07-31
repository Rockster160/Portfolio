# == Schema Information
#
# Table name: execution_archives
#
#  id            :bigint           not null, primary key
#  auth_type     :integer
#  finished_at   :datetime
#  started_at    :datetime
#  status        :integer
#  trigger_scope :string
#  created_at    :datetime         not null
#  auth_type_id  :integer
#  task_id       :bigint
#  user_id       :bigint
#
class ExecutionArchive < ApplicationRecord
  belongs_to :user
  belongs_to :task, optional: true

  enum :auth_type, ::Execution.auth_types
  enum :status, ::Execution.statuses

  scope :finished, -> { where.not(finished_at: nil) }

  def readonly?
    persisted?
  end

  def duration
    return unless finished_at? && started_at?

    finished_at - started_at
  end
end
