# == Schema Information
#
# Table name: executions
#
#  id            :bigint           not null, primary key
#  auth_type     :integer
#  finished_at   :datetime
#  started_at    :datetime
#  status        :integer          default("started")
#  trigger_scope :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  auth_type_id  :integer
#  payload_id    :bigint
#  task_id       :bigint
#  user_id       :bigint
#
class Execution < ApplicationRecord
  belongs_to :user
  belongs_to :task, optional: true
  belongs_to :payload, class_name: "ExecutionPayload", optional: true, inverse_of: :execution

  delegate :code, :ctx, :input_data, to: :payload, allow_nil: true

  scope :finished, -> { where.not(finished_at: nil) }
  scope :compactable, -> { where.not(payload_id: nil) }
  scope :with_duration, -> {
    where.not(finished_at: nil, started_at: nil)
      .select("*, AVG(EXTRACT(EPOCH FROM (finished_at - started_at)) * 1000) AS duration")
      .group(:id)
  }

  enum :auth_type, {
    guest:    1,  # + guest user id
    userpass: 2,  # + user id
    run:      3,  # + user id
    api_key:  4,  # + api key id
    jwt:      5,  # + user id
    trigger:  6,  # + source task id | nil means internal trigger
    exec:     7,  # + source task id
    cron:     8,  # nil - task self-fired via its own cron schedule
    words:    9,  # nil - voice/text command processed via Jarvis (always the owner)
    agenda:   10, # + agenda_item id - fired by an AgendaItem with kind=trigger
    buddy:    11, # + acting user id - Buddy fired it on that person's behalf.
                  #   Differs from execution.user_id whenever the task was
                  #   shared: the task runs as its owner, the actor is whoever
                  #   was talking to Buddy. See BuddyTaskRun for the full audit.
  }

  enum :status, {
    started:   0,
    cancelled: 1,
    success:   2,
    failed:    3,
  }

  def self.average_duration(count)
    finished.order(:started_at).limit(count).map(&:duration).then { |a| a.sum.to_f / a.length }
  end

  # Usage/billing questions have to span both halves of the log: rows inside
  # ExecutionArchiveWorker::RETENTION live here, everything older was moved to
  # execution_archives. Querying `executions` alone silently under-reports, so
  # anything that bills or charts should come through here.
  UNION_SQL = <<~SQL.squish.freeze
    (SELECT user_id, task_id, status, started_at FROM executions
     UNION ALL
     SELECT user_id, task_id, status, started_at FROM execution_archives)
  SQL

  BUCKET_UNITS = %w[hour day week month].freeze

  def self.usage_count(since:, until_at: Time.current, user: nil)
    where_sql, args = usage_conditions(since, until_at, user)
    sql = sanitize_sql_array(
      ["SELECT COUNT(*) FROM #{UNION_SQL} AS all_executions WHERE #{where_sql}", *args],
    )

    connection.select_value(sql).to_i
  end

  # => [[bucket_time, count], ...] across the full retained history.
  def self.usage_over_time(since:, until_at: Time.current, user: nil, bucket: :day)
    unit = BUCKET_UNITS.include?(bucket.to_s) ? bucket.to_s : "day"
    where_sql, args = usage_conditions(since, until_at, user)
    sql = sanitize_sql_array(
      [
        "SELECT date_trunc(?, started_at) AS bucket, COUNT(*) " \
        "FROM #{UNION_SQL} AS all_executions WHERE #{where_sql} GROUP BY 1 ORDER BY 1",
        unit,
        *args,
      ],
    )

    connection.select_rows(sql).map { |bucket_at, count| [bucket_at, count.to_i] }
  end

  def self.usage_conditions(since, until_at, user)
    conditions = ["started_at >= ?", "started_at < ?"]
    args = [since, until_at]

    if user.present?
      conditions << "user_id IN (?)"
      args << ::User.ids(user)
    end

    [conditions.join(" AND "), args]
  end
  private_class_method :usage_conditions

  def serialize
    super(except: [
      :id,
      :created_at,
      :updated_at,
      :task_id,
      :user_id,
      :payload_id,
    ]).merge(
      (ctx || {}).deep_symbolize_keys.slice(:error, :output, :line),
    )
  end

  def error
    (ctx || {}).deep_symbolize_keys[:error]
  end

  def result
    (ctx || {}).deep_symbolize_keys[:return_val]
  end

  def output
    (ctx || {}).deep_symbolize_keys[:output]
  end

  def duration
    return unless finished_at?

    finished_at - started_at
  end

  def last_completion_time
    Time.use_zone(user.timezone) { finished_at&.to_fs(:compact_week_month_time_sec) }
  end

  def stop_propagation?
    !!(ctx || {}).deep_symbolize_keys[:stop_propagation]
  end

  AUTH_RECORD_CLASSES = {
    guest:    "User",
    userpass: "User",
    run:      "User",
    jwt:      "User",
    api_key:  "ApiKey",
    trigger:  "Task",
    exec:     "Task",
  }.freeze

  def auth_record
    return if auth_type_id.blank?

    AUTH_RECORD_CLASSES[auth_type&.to_sym]&.safe_constantize&.find_by(id: auth_type_id)
  end

  def auth_label
    return "unknown" if auth_type.blank? && auth_type_id.blank?

    klass = AUTH_RECORD_CLASSES[auth_type&.to_sym]
    label = klass.presence || auth_type
    auth_type_id.present? ? "#{label}##{auth_type_id}" : label.to_s
  end
end
