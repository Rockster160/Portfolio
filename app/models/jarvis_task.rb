# == Schema Information
#
# Table name: jarvis_tasks
#
#  id              :bigint           not null, primary key
#  cron            :text
#  enabled         :boolean          default(TRUE)
#  input           :text
#  last_ctx        :jsonb
#  last_trigger_at :datetime
#  listener        :text
#  name            :text
#  next_trigger_at :datetime
#  output_text     :text
#  output_type     :integer          default("any")
#  return_data     :jsonb
#  sort_order      :integer
#  tasks           :jsonb
#  trigger         :integer          default("cron")
#  uuid            :uuid
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint
#

# Scheduled for removal: `cron` (Replaced by `input`)
class JarvisTask < ApplicationRecord
  include Orderable

  serialize :tasks, coder: ::BetterJsonSerializer
  serialize :last_ctx, coder: ::BetterJsonSerializer
  serialize :return_data, coder: ::BetterJsonSerializer

  belongs_to :user, required: true

  before_save :set_next_cron
  after_create { reload } # Needed to retrieve the generated uuid on the current instance in memory

  scope :by_listener, ->(listener) {
    safe_trigger = Regexp.escape(listener)
    where("listener ~* '(^|\\s)#{safe_trigger}(~|:|$)'")
  }
  scope :fuzzy_search, ->(q) { where("tasks::text ILIKE ?", "%#{q}%") }
  scope :enabled, -> { where(enabled: true) }

  orderable sort_order: :desc, scope: ->(task) { task.user.jarvis_tasks }

  AVAILABLE_TRIGGERS = [
    :callable,
    :cron,
    :action_event,
    :tell,
    :list,
    :calendar,
    # :email,
    :webhook,
    :websocket,
    # :websocket_expires,
    # :integration,
    # :failed_task,
    :function,
    :travel,
    :prompt,
    :monitor,
  ]

  enum trigger: {
    cron:              0,
    action_event:      1,
    tell:              2,
    list:              3,
    email:             4,
    webhook:           5,
    websocket:         6,
    websocket_expires: 7,
    # integration:     8, - Not needed, as "tell" can handle this
    failed_task:       9,
    function:          10,
    calendar:          11,
    travel:            12,
    prompt:            13,
    callable:          14,
    monitor:           15,
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

  def self.find_by_uuid(uuid) = find_by!(uuid: uuid)
  def self.anyfind(id)
    case id.to_s
    when /^(\w+-)+\w+$/i then find_by_uuid(id)
    when /^\d+$/i then find(id)
    else find_by!(name: id)
    end
  end
  def to_param = uuid

  def return_val=(new_val)
    self.return_data = { data: new_val }
  end
  def return_val
    return_data&.dig(:data) || output_text.to_s.split("\n").last
  end

  def listener_match?(trigger, &block)
    # TODO: trigger must be an exact, not partial match
    escape_listener = listener.dup
    tz = Tokenizer.new(escape_listener)
    tz.tokenize!(escape_listener, Tokenizer.wrap_regex("/"))
    tz.tokenize!(escape_listener, Tokenizer.wrap_regex("\""))
    tz.tokenize!(escape_listener, Tokenizer.wrap_regex("'"))
    tz.tokenize!(escape_listener, Tokenizer.wrap_regex("(", ")"))
    escape_listener.split(" ").all? { |sub_listener|
      unescaped_listener = tz.untokenize!(sub_listener)
      block.call(unescaped_listener)
    }
  end

  def pretty_log(trigger, trigger_data)
    message_data = (
      if trigger_data.is_a?(::String)
        trigger_data.truncate(100)
      else
        trigger_data.transform_values { |v| v.is_a?(::String) ? v.truncate(100) : v }
      end
    )
    PrettyLogger.info([
      PrettyLogger.colorize(:grey, "[#{name}]"),
      listener,
      "\n",
      PrettyLogger.pretty_message({
        trigger => message_data
      }.deep_symbolize_keys)
    ].join(""))
  end

  def match_run(trigger, trigger_data)
    first_match = nil
    return unless listener_match?(trigger) { |escaped_listener|
      matcher = ::SearchBreakMatcher.new(escaped_listener, { trigger => trigger_data })
      matcher.match?.tap { |m| first_match ||= matcher if m }
    }

    pretty_log(trigger, trigger_data)
    execute(trigger == :tell ? first_match.regex_match_data : trigger_data)
  end

  def serialize
    attributes.symbolize_keys.slice(
      :uuid,
      :name,
      :trigger,
      :output_type,
      :output_text,
      :cron,
      :enabled,
      :next_trigger_at,
      :last_trigger_at,
    ).merge(return_val: return_val)
  end

  def duplicate
    self.class.create!(
      attributes.symbolize_keys.except(
        :id,
        :uuid,
        :enabled,
        :last_ctx,
        :last_trigger_at,
        :output_text,
        :return_data,
        :created_at,
        :updated_at,
      ).tap { |attrs| attrs[:name] = "#{attrs[:name]} (2)" }
    )
  end

  def execute(data={})
    ::Jarvis::Execute.call(self, data)
  end

  def name
    return super unless persisted?

    super.presence || "Task ##{id}"
  end

  def humanized_schedule
    return trigger.titleize if trigger.present?

    cron
  end

  def to_op_data
    vals = [{ return: output_type.to_sym }]
    vals += input.split(/\r?\n/).map { |line|
      next line unless line.starts_with?(/\s*>/)
      tz = Tokenizer.new(line)
      tz.tokenize!(line, /\".*?\"/)
      full, name, type = line.match(/\s*>\s*(\w+):\s*(?::(\w+))?,?\s*/)&.to_a

      remaining = line.sub(full, "")
      _, array = remaining.match(/(\[.*?\])/)&.to_a
      next array[1..-2].split(/\s*,\s*/).map { |i| i.gsub(/^:/, "") } if array.present?

      str_opts = remaining.split(/\s*,\s*/)
      line_opts = {}.tap { |opts|
        opts[:optional] = true if str_opts.delete("optional")
        str_opts.each do |str_opt|
          k, v = str_opt.split(/:\s+:?/)
          v = tz.untokenize!(v).gsub(/^\"|\"$/, "")
          opts[k.to_sym] = (v.presence || true) if k.present?
        end
      }

      { block: type, **line_opts }
    }.compact
    # Add the name as the title in case there isn't anything else
    vals << name if vals.one? && vals.first.try(:keys) == [:return]

    [name, vals]
  end

  def inputs
    return unless function?
    # Choose date:
    # > from: :date, optional, default: Now
    # > multiplier: [seconds, minutes, hours]
    # > other: :str, label: Hello World
    input.to_s.split(/\r?\n/).map { |line|
      next unless line.starts_with?(/\s*>/)
      full, key, type = line.match(/\s*>\s*(\w+):\s*(?::(\w+))?,?\s*/)&.to_a
      type ||= :str

      [key, [
        { return: type },
        key.titleize
      ]]
    }.compact
  end

  private

  def set_next_cron
    self.next_trigger_at = ::CronParse.next(input) if cron? && input.present?
  end
end
