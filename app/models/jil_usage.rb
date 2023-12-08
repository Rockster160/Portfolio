# == Schema Information
#
# Table name: jil_usages
#
#  id         :bigint           not null, primary key
#  data       :jsonb
#  date       :date
#  executions :integer
#  icount     :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class JilUsage < ApplicationRecord
  include IndifferentJsonb
  belongs_to :user

  indifferent_jsonb :data
  # data: {
  #   uuid: { itotal: 1234, executions: 123 }
  # }

  def self.range_splitter(range)
    if range.is_a?(Date)
      [range, range]
    elsif range.is_a?(Range) && range.begin.is_a?(Date) && range.end.is_a?(Date)
      [range.begin, range.end]
    else
      raise ArgumentError, 'Invalid range. Please provide a single date or a date range.'
    end
  end

  def self.sum_totals_by_user(user, range)
    result = where(user_id: user.id, date: range)
      .select("
        SUM(icount) AS total_icount,
        SUM(executions) AS total_executions
      ").group(:user_id, :id).first

    { icount: result&.total_icount.to_i, executions: result&.total_executions.to_i }
  end

  def self.sum_totals_by_task(task, range)
    result = where(user_id: task.user_id, date: range)
      .select("
        COALESCE(SUM((data->'#{task.uuid}'->>'itotal')::integer), 0) AS total_icount,
        COALESCE(SUM((data->'#{task.uuid}'->>'executions')::integer), 0) AS total_executions
      ").group(:user_id, :id).first

    { icount: result&.total_icount.to_i, executions: result&.total_executions.to_i }
  end

  # Because Rails will load the object in memory and then update it, using the connection.execute
  #   will ensure that the numbers do not get loaded by other threads and then updated incorrectly.
  def increment(task, task_iterations)
    a = self.class.where(id: id).update_all("
      icount = COALESCE(icount::integer, 0) + #{task_iterations},
      executions = COALESCE(executions::integer, 0) + 1,
      -- increment the nested data values
      data = (
      SELECT COALESCE(data, '{}'::jsonb) ||
        jsonb_build_object(
          '#{task.uuid}',
          jsonb_build_object(
            'executions', COALESCE((data->'#{task.uuid}'->>'executions')::integer, 0) + 1,
            'itotal', COALESCE((data->'#{task.uuid}'->>'itotal')::integer, 0) + #{task_iterations}
          )
        )
    )
    ")
  end
end
