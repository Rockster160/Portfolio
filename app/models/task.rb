# == Schema Information
#
# Table name: tasks
#
#  id              :bigint           not null, primary key
#  archived_at     :datetime
#  buddy_enabled   :boolean          default(FALSE), not null
#  code            :text
#  cron            :text
#  description     :text
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
  # Listener is a single bare scope token - no `:` data filters, no regex,
  # not a function signature. These are the only tasks that can be fired
  # by name alone (`Jil.trigger(user, scope, {})`) without constructing a
  # payload, which is what Buddy's trigger tool does.
  scope :plain_scopes, -> {
    where("listener ~ ?", '^[a-zA-Z][a-zA-Z0-9_-]*$')
  }
  # Owner opted this task in to assistant invocation. Independent of
  # shared_tasks - that governs which humans can see/run it, this governs
  # whether Buddy may fire it for whoever it IS visible to.
  scope :buddy_visible, -> {
    enabled.active.buddy_enabled.where("name IS NOT NULL AND name != ''")
  }
  scope :buddy_enabled, -> { where(buddy_enabled: true) }
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
    data = {
      folders:      TaskFolder.all.map(&:attributes),
      tasks:        all.map(&:attributes),
      shared_tasks: SharedTask.all.map(&:attributes),
    }
    key = "tasks/export-#{Time.current.strftime("%Y%m%d-%H%M%S")}.json"
    ::FileStorage.upload(data.to_json, filename: key, bucket: bucket)
    key
  end

  def self.s3_import(key, bucket: FileStorage::DEFAULT_BUCKET)
    if Rails.env.production? && ENV["SKIP_PROD"] != "true"
      raise "DANGEROUS! DO NOT EXECUTE IN PROD! Pass `SKIP_PROD=true` to bypass"
    end

    json = ::FileStorage.mode(:s3) { ::FileStorage.download(key, bucket: bucket) }
    data = JSON.parse(json)

    # Support legacy exports that are just an array of tasks
    if data.is_a?(Array)
      return data.map { |attrs|
        task = find_or_initialize_by(uuid: attrs["uuid"])
        task.assign_attributes(attrs.except("uuid"))
        task.save!
        task
      }
    end

    # Wipe existing data in FK-safe order
    SharedTask.delete_all
    Task.delete_all
    TaskFolder.delete_all

    # Import folders topologically -  parents before children at any depth
    folders = (data["folders"] || []).index_by { |f| f["id"] }
    imported = Set.new
    import_folder = ->(attrs) {
      return if imported.include?(attrs["id"])

      import_folder.call(folders[attrs["parent_id"]]) if attrs["parent_id"] && folders[attrs["parent_id"]]
      folder = TaskFolder.find_or_initialize_by(id: attrs["id"])
      folder.assign_attributes(attrs)
      folder.save!
      imported << attrs["id"]
    }
    folders.each_value { |attrs| import_folder.call(attrs) }

    # Import tasks
    tasks = (data["tasks"] || []).map { |attrs|
      task = find_or_initialize_by(uuid: attrs["uuid"])
      task.assign_attributes(attrs.except("uuid"))
      task.save!
      task
    }

    # Import shared_tasks
    (data["shared_tasks"] || []).each { |attrs|
      st = SharedTask.find_or_initialize_by(id: attrs["id"])
      st.assign_attributes(attrs)
      st.save!
    }

    tasks
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

  def function?
    listener.to_s.match?(self.class.func_regex)
  end

  # Raw args string from a `function(...)` listener, e.g.
  # `name:String action:["flash" "pulse"]`. Returns nil if not a function
  # or function has no args.
  def function_args_str
    match = listener.to_s.match(self.class.func_regex)
    return nil if match.blank?

    match[:args].to_s.strip.presence
  end

  # The `params` array to send alongside named args, built from THIS task's
  # declared arg order rather than the order the caller wrote its keys in. See
  # Jil::FunctionSignature for why the caller's order can't be trusted.
  def function_params(named_args)
    ::Jil::FunctionSignature.params(function_args_str, named_args)
  end

  def monitor
    return unless listener.to_s.starts_with?("monitor:")

    listener.to_s.gsub(/^monitor::?/i, "")
  end

  def monitor?
    trigger_type == :monitor
  end

  def average_duration(count)
    executions.finished.order(:started_at).limit(count).map(&:duration).then { |a| a.sum.to_f / a.length }
  end

  # Ordered by started_at, not finished_at: only started_at is indexed
  # (task_id, started_at DESC), and ordering on finished_at forced a sort of
  # every execution the task has ever logged — ~6s once a task passed a
  # million rows. For a serialized task the two orderings agree; when runs do
  # overlap, started_at is the better answer anyway, since the caller wants
  # the run it just kicked off, not whichever one happened to finish last.
  def last_execution
    @last_execution ||= executions.finished.order(:started_at).last
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

  # Matching lives in Jil::ListenerMatch so a Buddy watch written in the same
  # syntax is matched by the same code — see that file for why.
  def match_run(trigger, trigger_data, force: false, auth: :trigger, auth_id: nil)
    did_match, first_match = ::Jil::ListenerMatch.match_with_captures(listener, trigger, trigger_data)
    return if !did_match && !force

    ::Jarvis.log("[#{id}]\e[35m#{listener}")

    # pretty_log(trigger, trigger_data) if Rails.env.development?
    execute(
      trigger_data.merge(first_match&.match_data || { match_list: [], named_captures: {} }),
      auth: auth, auth_id: auth_id, trigger_scope: trigger.to_s,
    )
  end

  # Adopt the executor's own Execution as `last_execution` rather than
  # clearing the memo. The trigger loop calls `stop_propagation?` on every
  # task it runs, and re-querying for the row we just wrote costs a lookup
  # per trigger for an object already in memory.
  def execute(data={}, broadcast_task: nil, auth: :trigger, auth_id: nil, trigger_scope: nil)
    ::Jil::Executor.call(
      user, code, data,
      task: self, broadcast_task: broadcast_task || self,
      auth: auth, auth_id: auth_id, trigger_scope: trigger_scope
    ).tap { |executor| @last_execution = executor.execution }
  end

  def accessible_by?(user)
    return false unless user

    user_id == user.id || shared_users.exists?(user.id)
  end

  # Which Buddy index this task lands in, if any. `:unsupported` means there
  # is no listener at all (cron-only, or nothing wired) - there is no scope to
  # fire and no signature to call, so `buddy_enabled` would do nothing. The
  # config modal warns on that.
  #
  # Everything with a listener is a `:trigger`: Buddy fires the scope and
  # supplies matching data, exactly like `trigger <scope>:<key>:<value>`. That
  # covers filtered listeners (`event:add name::X`) as well as bare scopes.
  def buddy_kind
    return :unsupported if listener.blank?
    return :function if listener.to_s.match?(/(^|\s)function\(/i)

    :trigger
  end

  # Leading token of the listener - the scope `Jil.trigger` matches on.
  # `event:add name::Transaction` -> "event"; `monitor::deploy` -> "monitor".
  def trigger_scope
    return nil unless buddy_kind == :trigger

    listener.to_s.strip.split(":").first.presence
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
