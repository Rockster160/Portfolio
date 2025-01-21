# == Schema Information
#
# Table name: tasks
#
#  id              :bigint           not null, primary key
#  code            :text
#  cron            :text
#  enabled         :boolean          default(TRUE)
#  last_trigger_at :datetime
#  listener        :text
#  name            :text
#  next_trigger_at :datetime
#  sort_order      :integer
#  uuid            :uuid
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint
#
class Task < ApplicationRecord
  include ::Orderable
  belongs_to :user, required: true

  before_save :set_next_cron
  after_create { reload } # Needed to retrieve the generated uuid on the current instance in memory
  orderable sort_order: :desc, scope: ->(task) { task.user.tasks }

  has_many :executions

  scope :enabled, -> { where(enabled: true) }
  scope :functions, -> {
    where("listener ~* '(^|\\s)function\\('")
  }
  scope :by_method_name, ->(name) {
    where("REPLACE(REGEXP_REPLACE(name, '\\W+', '', 'g'), ' ', '_') = ?", name)
  }
  scope :by_snake_name, ->(name) {
    where("LOWER(REPLACE(REGEXP_REPLACE(name, '\\W+', '', 'g'), ' ', '_')) = ?", name)
  }
  scope :by_listener, ->(listener) {
    safe_trigger = Regexp.escape(listener)
    where("listener ~* '(^|\\s)#{safe_trigger}(~|:|$)'")
  }
  scope :by_code, ->(code) {
    ilike(code: "%#{code}%")
  }

  def self.links
    ids.each { |id| puts "https://ardesian.com/jil/tasks/#{id}" };nil
  end

  def self.last_exe
    ::Execution.finished.order(:finished_at).last
  end

  def self.last_error
    ::Execution.finished.failed.order(:finished_at).last&.ctx&.then { |ctx|
      ctx = ctx.deep_symbolize_keys
      {
        timestamp: Time.zone.parse(ctx[:time_complete]),
        error: ctx[:error],
        line: ctx[:error_line],
      }
    }
  end

  # refactor_function("ActionEvent.update") { |line| line.methodname = "change" }
  def self.refactor_function(function_call, &refactor)
    by_code(function_call).find_each do |task|
      puts "\e[94m===== [#{task.id}] #{task.name} =====\e[0m" if Rails.env.development?
      parser = ::Jil::Parser.breakdown(task.code) { |line|
        next line unless "#{line.varname} = #{line.objname}.#{line.methodname}(...)::#{line.cast}".include?(function_call)

        puts "\e[33m#{line}\e[0m" if Rails.env.development?
        refactor.call(line)
        puts "\e[36m#{line}\e[0m" if Rails.env.development?

        line
      }
      task.update(code: parser.map(&:to_s).join("\n"))
    end
  end

  def self.func_regex
    /^\s*function(?:\((?<args>.*)\))(?:::(?<cast>[A-Z][_0-9A-Za-z|]*))?\s*$/i
  end

  def self.schema(user=nil)
    tasks = user.present? ? user.tasks.enabled.functions : none
    funcs = "[Custom]\n" + tasks.filter_map { |task|
      match = task.listener.match(func_regex)
      next unless match.present?

      [
        "  #",
        task.name.gsub(/\W+/, "").gsub(" ", "_"),
        "(", match[:args], ")::#{match[:cast] || :Any}",
      ].join("")
    }.join("\n")

    (funcs + "\n" + File.read("app/service/jil/schema.txt")).html_safe
  end

  def trigger_type
    listener.to_s.split(":", 2).first.presence&.to_sym
  end

  def average_duration(count)
    executions.finished.order(:finished_at).limit(count).map(&:duration).then { |a| a.sum.to_f / a.length }
  end

  def last_execution
    @last_execution ||= executions.finished.order(:finished_at).last
  end

  def last_error
    last_execution&.error
  end

  def last_message
    last_result&.then { |r| r.is_a?(::String) ? r : nil }
  end

  def last_result
    last_execution&.result
  end

  def last_output
    last_execution&.output
  end

  def last_completion_time
    last_execution&.last_completion_time
  end

  def stop_propagation?
    !!last_execution&.stop_propagation?
  end

  def legacy_serialize
    attributes.deep_symbolize_keys.except(:created_at, :updated_at, :code, :cron, :sort_order)
  end

  def serialize_with_execution
    legacy_serialize.merge(last_execution&.legacy_serialize || {})
  end

  def listener_match?(trigger, &block)
    return false unless trigger.to_s.downcase == listener.to_s.downcase.split(":").first

    Tokenizer.split(listener).all? { |sub_listener|
      block.call(sub_listener)
    }
  end

  def match_run(trigger, trigger_data, force: false)
    first_match = nil
    did_match = listener_match?(trigger) { |sub_listener|
      next true if sub_listener == trigger
      matcher = ::SearchBreakMatcher.new(sub_listener, { trigger => trigger_data })
      matcher.match?.tap { |m| first_match ||= matcher if m }
    }
    return if !did_match && !force
    ::Jarvis.log("[#{id}]\e[35m#{listener}")

    # pretty_log(trigger, trigger_data) if Rails.env.development?
    execute(trigger_data.merge(first_match&.regex_match_data || { match_list: [], named_captures: {} }))
  end

  def execute(data={})
    ::Jil::Executor.call(user, code, data, task: self).tap { @last_execution = nil }
  end

  private

  def set_next_cron
    self.next_trigger_at = ::CronParse.next(cron, user) if cron.present?
  end
end
