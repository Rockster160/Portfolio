# == Schema Information
#
# Table name: tasks
#
#  id              :bigint           not null, primary key
#  archived_at     :datetime
#  code            :text
#  cron            :text
#  enabled         :boolean          default(TRUE)
#  last_status     :integer
#  last_trigger_at :datetime
#  listener        :text
#  name            :text
#  next_trigger_at :datetime
#  sort_order      :integer
#  tree_order      :integer
#  uuid            :uuid
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  task_folder_id  :bigint
#  user_id         :bigint
#
class Task < ApplicationRecord
  include ::Orderable

  belongs_to :user, optional: false
  belongs_to :task_folder, optional: true

  before_save :set_next_cron
  after_create { reload } # Needed to retrieve the generated uuid on the current instance in memory
  orderable sort_order: :desc, scope: ->(task) { task.user.tasks }
  scope :ordered, -> { order(tree_order: :desc) } # Override Orderable: tree-aware global ordering
  before_save -> { self.tree_order ||= (user&.tasks&.maximum(:tree_order) || 0) + 1 }

  has_many :executions
  has_many :shared_tasks, dependent: :destroy
  has_many :shared_users, through: :shared_tasks, source: :user

  enum :last_status, ::Execution.statuses

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :enabled, -> { where(enabled: true) }
  scope :pending, -> { where(next_trigger_at: ..Time.current) }
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

  # Walk the folder tree in display order and assign sequential tree_order values.
  # Higher tree_order = displayed first (DESC). 2 SELECTs + 1 UPDATE.
  def self.recompute_tree_order(user)
    all_folders = user.task_folders.to_a
    all_tasks = user.tasks.active.to_a
    folders_by_parent = all_folders.group_by(&:parent_id)
    tasks_by_folder = all_tasks.group_by(&:task_folder_id)

    ordered_task_ids = []
    walk = ->(parent_id) {
      child_folders = (folders_by_parent[parent_id] || [])
      child_tasks = (tasks_by_folder[parent_id] || [])
      items = (
        child_folders.map { |f| [:folder, f] } +
        child_tasks.map { |t| [:task, t] }
      ).sort_by { |_type, item| -(item.sort_order || 0) }

      items.each do |type, item|
        if type == :folder
          walk.call(item.id)
        else
          ordered_task_ids << item.id
        end
      end
    }

    walk.call(nil)
    return if ordered_task_ids.empty?

    total = ordered_task_ids.size
    cases = ordered_task_ids.each_with_index.map { |id, idx|
      "WHEN #{id.to_i} THEN #{total - idx}"
    }.join(" ")
    user.tasks.active.update_all("tree_order = CASE id #{cases} ELSE 0 END")
  end

  def self.links
    ids.each { |id| puts "https://ardesian.com/jil/tasks/#{id}" }
    nil
  end

  def self.s3_export(bucket: FileStorage::DEFAULT_BUCKET)
    data = all.map(&:attributes)
    key = "tasks/export-#{Time.current.strftime("%Y%m%d-%H%M%S")}.json"
    ::FileStorage.upload(data.to_json, filename: key, bucket: bucket)
    key
  end

  def self.s3_import(key, bucket: FileStorage::DEFAULT_BUCKET)
    json = ::FileStorage.download(key, bucket: bucket)
    data = JSON.parse(json)

    data.map { |attrs|
      task = find_or_initialize_by(uuid: attrs["uuid"])
      task.assign_attributes(attrs.except("uuid"))
      task.save!
      task
    }
  end

  def self.last_exe
    ::Execution.finished.order(:finished_at).last
  end

  def self.last_error
    ::Execution.finished.failed.order(:finished_at).last&.ctx&.then { |ctx|
      ctx = ctx.deep_symbolize_keys
      {
        timestamp: Time.zone.parse(ctx[:time_complete]),
        error:     ctx[:error],
        line:      ctx[:error_line],
      }
    }
  end

  # TODO: When renaming a function, should call the refactor to go through and edit all of the tasks below to change the call

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
    tasks = user.present? ? user.tasks.active.enabled.functions : none
    funcs = "[Custom]\n" + tasks.filter_map { |task|
      match = task.listener.match(func_regex)
      next if match.blank?

      [
        "  #",
        task.name.gsub(/\W+/, "").gsub(" ", "_"),
        "(",
        match[:args],
        ")::#{match[:cast] || :Any}",
      ].join
    }.join("\n")

    (funcs + "\n" + File.read("app/service/jil/schema.txt")).html_safe
  end

  def trigger_type
    listener.to_s.split(":", 2).first.presence&.to_sym
  end

  def monitor
    return unless listener.to_s.starts_with?("monitor:")

    listener.to_s.gsub(/^monitor::?/i, "")
  end

  def monitor?
    trigger_type == :monitor
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

  def serialize(opts={})
    super(opts.reverse_merge(except: [:created_at, :updated_at, :code, :cron, :sort_order, :tree_order, :archived_at]))
  end

  def serialize_with_execution
    with_jil_attrs(last_execution&.serialize || {})
  end

  def listener_match?(trigger, &block)
    return false unless trigger.to_s.downcase == listener.to_s.downcase.split(":").first

    Tokenizer.split(listener).all? { |sub_listener|
      block.call(sub_listener)
    }
  end

  def match_run(trigger, trigger_data, force: false)
    first_match = nil
    serialized_data = TriggerData.serialize(trigger_data, use_global_id: false)
    did_match = listener_match?(trigger) { |sub_listener|
      next true if sub_listener == trigger

      if trigger == :monitor && trigger_data.is_a?(::Hash)
        next true if sub_listener.match?(/\A\s*monitor::?#{trigger_data[:channel]}\s*\z/)
      end

      matcher = ::SearchBreakMatcher.new(sub_listener, { trigger => serialized_data })
      matcher.match?.tap { |m| first_match ||= matcher if m }
    }
    return if !did_match && !force

    ::Jarvis.log("[#{id}]\e[35m#{listener}")

    # pretty_log(trigger, trigger_data) if Rails.env.development?
    execute(trigger_data.merge(first_match&.regex_match_data || { match_list: [], named_captures: {} }))
  end

  def execute(data={}, broadcast_task: nil)
    ::Jil::Executor.call(user, code, data, task: self, broadcast_task: broadcast_task || self).tap { @last_execution = nil }
  end

  def accessible_by?(user)
    return false unless user

    user_id == user.id || shared_users.exists?(user.id)
  end

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current, task_folder_id: nil)
    Task.recompute_tree_order(user)
  end

  def unarchive!
    update!(archived_at: nil)
    Task.recompute_tree_order(user)
  end

  def broadcast_users
    shared_ids = SharedTask.where(task_id: id).pluck(:user_id)
    User.where(id: [user_id] + shared_ids)
  end

  private

  def set_next_cron
    prior_trigger = next_trigger_at
    self.next_trigger_at = cron.present? ? ::CronParse.next(cron, user) : nil
    if prior_trigger != next_trigger_at
      ::Jil.trigger(user, :task, with_jil_attrs(changed: { next_trigger_at: next_trigger_at }))
    end
  end
end
