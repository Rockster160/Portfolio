# == Schema Information
#
# Table name: jarvis_tasks
#
#  id              :bigint           not null, primary key
#  cron            :text
#  input           :text
#  last_ctx        :jsonb
#  last_result     :text
#  last_trigger_at :datetime
#  name            :text
#  next_trigger_at :datetime
#  output_type     :integer          default("any")
#  tasks           :jsonb
#  trigger         :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint
#
class JarvisTask < ApplicationRecord
  belongs_to :user, required: true
  serialize :tasks, SafeJsonSerializer
  serialize :last_ctx, SafeJsonSerializer

  AVAILABLE_TRIGGERS = [
    :cron,
    :action_event,
    :tell,
    # :list,
    # :email,
    :webhook,
    # :websocket,
    # :websocket_expires,
    # :integration,
    # :failed_task,
    # :function,
  ]

  scope :without_fn, -> { where.not(trigger: :function).or(where(trigger: nil)) }
  scope :cron, -> { where(trigger: nil).where.not(next_trigger_at: nil) }

  enum trigger: {
    cron:              nil,
    action_event:      1,
    tell:              2,
    list:              3,
    email:             4,
    webhook:           5,
    websocket:         6,
    websocket_expires: 7,
    integration:       8,
    failed_task:       9,
    function:          10,
  }

  enum output_type: {
    any:      1,
    str:      2,
    bool:     3,
    num:      4,
    duration: 5,
    date:     6,
    array:    7,
    hash:     8,
    keyval:   9,
  }, _prefix: :output #.output_any?

  def humanized_schedule
    return trigger.titleize if trigger.present?

    cron
  end

  def to_op_data
    vals = [{ return: output_type.to_sym }]
    vals += input.split(/\r?\n/).map { |line|
      next line unless line.starts_with?(/\s*>/)
      full, name, type = line.match(/\s*>\s*(\w+):\s*(?::(\w+))?,?\s*/)&.to_a

      remaining = line.sub(full, "")
      _, array = remaining.match(/(\[.*?\])/)&.to_a
      next array[1..-2].split(/\s*,\s*/).map { |i| i.gsub(/^:/, "") } if array.present?

      str_opts = remaining.split(/\s*,\s*/)
      line_opts = {}.tap { |opts|
        opts[:optional] = true if str_opts.delete("optional")
        str_opts.each do |str_opt|
          k, v = str_opt.split(/:\s+:?/)
          opts[k.to_sym] = (v || true) if k.present?
        end
      }

      { block: type, **line_opts }
    }.compact
    [name, vals]
  end

  def inputs
    # Choose date:
    # > from: :date, optional, default: Now
    # > multiplier: [seconds, minutes, hours]
    # > other: :str, label: Hello World
    input.split(/\r?\n/).map { |line|
      next unless line.starts_with?(/\s*>/)
      full, key, type = line.match(/\s*>\s*(\w+):\s*(?::(\w+))?,?\s*/)&.to_a
      type ||= :str

      [key, [
        { return: type },
        key.titleize
      ]]
    }.compact
  end
end
