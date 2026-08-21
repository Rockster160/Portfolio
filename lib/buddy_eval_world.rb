# The world the eval probes are asked about, built once and taken back down.
#
# Half the probes ask about something that has to already exist: you can't test
# "rename the recycling chore" against a household with no recycling chore, and
# a miss there says nothing about whether the model can find `edit_chore`.
# Those probes carry a `needs:` so their failures are reported apart from the
# rest, and until now that was the whole answer — a third of the sweep was
# permanently unanswerable.
#
# So: build the lot, run everything against it, put it back.
#
# WHAT THIS WRITES TO. The eval runs against the acting person's real
# development database, because that's where their household, their lists and
# their Jil tasks are, and a probe answered against an empty database isn't
# answering the question. That means this really does create a chore called
# "Take out the recycling" in the same table as their own.
#
# Three things keep that honest:
#
#   1. It refuses to run anywhere but development and test.
#   2. Every record is written to a MANIFEST on disk as it's created, by class
#      and id, before the next one is built. Teardown reads the manifest, so a
#      run that dies halfway — or gets killed — leaves an exact list of what to
#      remove rather than a pattern to guess with.
#   3. `BuddyEvalWorld.sweep!` removes whatever a previous run left behind, and
#      `rake buddy:eval_world_clear` is that from the outside.
#
# What it deliberately does NOT fake: the printer being reachable, and a
# proposal in the thread for `undo` to reverse. Both are live state rather than
# rows, and a stand-in for either would be testing the stand-in.
class BuddyEvalWorld
  MANIFEST = "tmp/buddy_eval/world.json".freeze

  class << self
    def build!(user)
      unless Rails.env.local?
        raise "the eval world writes real records - development or test only"
      end

      sweep!
      new(user).tap(&:build!)
    end

    # Whatever a previous run left behind. Safe to call when there's nothing.
    def sweep!
      path = Rails.root.join(MANIFEST)
      return 0 unless path.exist?

      rows = JSON.parse(path.read) rescue []
      gone = destroy_rows(rows)
      path.delete
      gone
    end

    # Reverse order, so a child is never orphaned by its parent going first.
    # Each destroy is independently rescued: one row that has already been
    # removed by hand must not strand the fifty after it.
    def destroy_rows(rows)
      rows.reverse.count { |row| destroy_row(row) }
    end

    def destroy_row(row)
      klass, id = row.values_at("class", "id")
      return false if klass.blank?

      if klass == "AmazonOrder"
        order = AmazonOrder.all.find { |o| o.id.to_s == id.to_s }
        return false if order.nil?

        order.destroy
        AmazonOrder.commit! if AmazonOrder.respond_to?(:commit!)
      else
        record = klass.constantize.find_by(id: id)
        return false if record.nil?

        record.destroy!
      end
      true
    rescue StandardError => e
      warn "[eval world] couldn't remove #{row["class"]}##{row["id"]}: #{e.class}: #{e.message}"
      false
    end
  end

  attr_reader :user, :made

  def initialize(user)
    @user = user
    @made = []
  end

  def build!
    chores!
    lists!
    events!
    reminders!
    agenda!
    ideas!
    glossary!
    routines!
    links!
    deliveries!
    jil_tasks!
    self
  end

  def teardown!
    self.class.destroy_rows(made.map(&:stringify_keys)).tap { manifest_path.delete if manifest_path.exist? }
  end

  # What got built, for the run header — a sweep that reports "0/24 preconditions
  # met" because the world silently failed to build is worse than one that says
  # which half is missing.
  def summary
    made.group_by { |row| row[:class] }.transform_values(&:length).sort.map { |k, n| "#{k} x#{n}" }
  end

  private

  # Recorded BEFORE the next record is built, so a crash between two writes
  # still leaves the first one on the list.
  def track(record)
    @made << { class: record.class.name, id: record.id }
    manifest_path.dirname.mkpath
    manifest_path.write(JSON.pretty_generate(@made.map(&:stringify_keys)))
    record
  end

  def manifest_path
    @manifest_path ||= Rails.root.join(MANIFEST)
  end

  def household
    @household ||= user.chore_household
  end

  def chores!
    return if household.nil?

    @recycling = track(
      Chore.create!(
        created_by_user: user, chore_household: household, name: "Take out the recycling",
        reward_pebbles: 2, recurrence: { freq: :weekly, by_day: %w[tue] }
      ),
    )
    @water = track(
      Chore.create!(
        created_by_user: user, chore_household: household, name: "Drink Water",
        reward_pebbles: 1, recurrence: { freq: :daily }
      ),
    )
    # One of each, today: `edit_chore_completion` and `undo_chore_completion`
    # both need a landed completion to talk about, and they are the two most
    # often confused with logging a fresh one.
    track(ChoreCompletion.create!(chore: @water, user: user, completed_at: 2.hours.ago, day_key: user.perceived_today))
    track(ChoreCompletion.create!(chore: @recycling, user: user, completed_at: 3.hours.ago, day_key: user.perceived_today))
  end

  # A list belongs to people through UserList, so a new one needs both rows —
  # and an existing Groceries list is reused rather than duplicated, because
  # two lists by that name would make "add it to the groceries" ambiguous in a
  # way nothing about the tool caused.
  def lists!
    list = user.lists.find_by("LOWER(name) = ?", "groceries")
    if list.nil?
      list = track(List.create!(name: "Groceries"))
      track(UserList.create!(user: user, list: list, is_owner: true))
    end
    track(ListItem.create!(list: list, name: "Oat milk"))
  end

  def events!
    track(ActionEvent.create!(user: user, name: "Strawberry Celsius", timestamp: 4.hours.ago))
    track(ActionEvent.create!(user: user, name: "Sandwich", timestamp: 5.hours.ago))
  end

  def reminders!
    convo = conversation
    return if convo.nil?

    ["water the tomatoes", "the vet appointment", "water the front flower bed"].each { |body|
      track(
        BuddyReminder.create!(
          user: user, byte_conversation: convo, body: body, fire_at: 6.hours.from_now,
        ),
      )
    }
  end

  def agenda!
    agenda = user.agendas.first
    return if agenda.nil?

    track(
      AgendaItem.create!(
        agenda: agenda, kind: :event, name: "Dentist",
        start_at: 1.day.from_now.change(hour: 15), end_at: 1.day.from_now.change(hour: 16)
      ),
    )
  end

  def ideas!
    track(
      BuddyMemory.create!(
        user: user, kind: :stash, status: :active, category: :home,
        content: "Sort out the greenhouse - the glass on the north side needs replacing"
      ),
    )
  end

  def glossary!
    return if household.nil?

    track(
      HouseholdGlossaryTerm.create!(
        chore_household: household, term: "bakkie", meaning: "a plastic tub, not a truck",
      ),
    )
  end

  # Steps have to be RUNNABLE — BuddyRoutine validates them against the
  # registry — so this is a real two-step routine rather than a placeholder.
  def routines!
    track(
      BuddyRoutine.create!(
        user: user, name: "Wind-down", description: "The evening one",
        steps: [
          { "tool_name" => "set_font_size", "payload" => { "size" => "normal" } },
          { "tool_name" => "set_timer", "payload" => { "minutes" => 10, "label" => "wind down" } },
        ]
      ),
    )
  end

  def links!
    track(
      RecordLink.create!(
        user: user, source_kind: :event, source_name: "Coffee",
        target_kind: :chore, target_name: "Drink Water"
      ),
    )
  rescue StandardError => e
    warn "[eval world] no record link: #{e.message}"
  end

  def deliveries!
    return unless Buddy::Deliveries.available?(user)

    ["desk", "mattress"].each { |name|
      order = Buddy::Deliveries.add!(user: user, name: name, on: 3.days.from_now.to_date)
      @made << { class: "AmazonOrder", id: order.id }
    }
    manifest_path.write(JSON.pretty_generate(@made.map(&:stringify_keys)))
  rescue StandardError => e
    warn "[eval world] no deliveries: #{e.message}"
  end

  # The house, the printer and the camera, as the three shapes the tools
  # actually distinguish: a FUNCTION with typed args, and a bare TRIGGER.
  def jil_tasks!
    return unless defined?(Task)

    {
      "Whisper Sound"    => "function(sound::String)",
      "Camera Last Seen" => "function(camera::String)",
      "Office Light"     => "function(color::String, brightness::Integer)",
      "Fan"              => "function(speed::String)",
    }.each { |name, signature|
      track(
        Task.create!(
          user: user, name: name, listener: signature, buddy_enabled: true, enabled: true,
          description: "#{name}, for the eval world"
        ),
      )
    }

    track(
      Task.create!(
        user: user, name: "Chill Mode", listener: "chill-mode", buddy_enabled: true, enabled: true,
        description: "The evening scene"
      ),
    )
  rescue StandardError => e
    warn "[eval world] no jil tasks: #{e.message}"
  end

  def conversation
    @conversation ||= user.byte_conversations.order(:id).first
  end
end
