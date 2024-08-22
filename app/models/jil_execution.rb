# == Schema Information
#
# Table name: jil_executions
#
#  id          :bigint           not null, primary key
#  code        :text
#  ctx         :jsonb
#  finished_at :datetime
#  input_data  :jsonb
#  started_at  :datetime
#  status      :integer          default("started")
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  jil_task_id :bigint
#  user_id     :bigint
#
class JilExecution < ApplicationRecord
  belongs_to :user
  belongs_to :jil_task, optional: true

  enum status: {
    started:   0,
    cancelled: 1,
    success:   2,
    failed:    3,
  }

  def serialize
    attributes.deep_symbolize_keys.except(
      :id,
      :created_at,
      :updated_at,
      :jil_task_id,
      :user_id,
      :input_data,
      :code,
      :ctx,
    ).merge(
      ctx.deep_symbolize_keys.slice(:error, :output, :line)
    )
  end

  def result
    (ctx || {}).deep_symbolize_keys[:return_val]
  end

  def output
    (ctx || {}).deep_symbolize_keys[:output]
  end
end
