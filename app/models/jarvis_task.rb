# == Schema Information
#
# Table name: jarvis_tasks
#
#  id              :bigint           not null, primary key
#  cron            :text
#  enabled         :boolean          default(TRUE)
#  input           :text
#  last_ctx        :jsonb
#  last_result     :text
#  last_result_val :text
#  last_trigger_at :datetime
#  name            :text
#  next_trigger_at :datetime
#  output_type     :integer          default("any")
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

  serialize :tasks, coder: ::SafeJsonSerializer
  serialize :last_ctx, coder: ::SafeJsonSerializer

  belongs_to :user, required: true

  before_save :set_next_cron
  after_create { reload } # Needed to retrieve the generated uuid on the current instance in memory

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
    :prompt_response,
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
    prompt_response:   13,
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

  def duplicate
    self.class.create!(
      attributes.symbolize_keys.except(
        :id,
        :uuid,
        :enabled,
        :last_ctx,
        :last_result,
        :last_result_val,
        :last_trigger_at,
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
    if function?
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
    elsif tell?
      [["Full Input", [
        { return: :str },
        "Full Input"
      ]]] + input.to_s.scan(/\{\w+/).map { |match|
        word = match[1..]
        [word, [
          { return: :str },
          word.titleize
        ]]
      }.uniq
    elsif list?
      [
        ["List Data", [
          { return: :hash },
          "List Data"
        ]],
        ["Item Name", [
          { return: :str },
          "Item Name"
        ]],
        ["Item Added", [
          { return: :bool },
          "Item Added"
        ]]
      ]
    elsif calendar?
      [["Event Data", [
        { return: :hash },
        "Event Data"
      ]]]
    elsif websocket?
      [
        ["WS Receive Data", [
          { return: :hash },
          "WS Receive Data"
        ]],
        ["Connection State", [
          { return: :str },
          "Connection State"
        ]]
      ]
    elsif monitor?
      [["Pressed", [
        { return: :bool },
        "Pressed"
      ]]]
    end
  end

  private

  def set_next_cron
    self.next_trigger_at = ::CronParse.next(input) if cron? && input.present?
  end
end
