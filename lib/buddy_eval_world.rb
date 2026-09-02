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
#   2. Every record is written to a manifest on disk as it's created, by class
#      and id, before the next one is built. Teardown reads the manifest, so a
#      run that dies halfway — or gets killed — leaves an exact list of what to
#      remove rather than a pattern to guess with.
#   3. `BuddyEvalWorld.sweep!` removes whatever a previous run left behind, and
#      `bx rails buddy:eval_world_clear` is that from the outside.
#
# What it deliberately does NOT fake: the printer being reachable, and a
# proposal in the thread for `undo` to reverse. Both are live state rather than
# rows, and a stand-in for either would be testing the stand-in.
class BuddyEvalWorld
  DIR = "tmp/buddy_eval".freeze

  # Must match the thread lib/tasks/buddy_eval.rake speaks in, or anything
  # seeded per-conversation is invisible to the turn that asks about it.
  EVAL_THREAD = "Eval · Byte".freeze

  # The smallest thing ByteImageNormalizer and every downstream reader accept as
  # a JPEG: a real one-pixel image rather than a few magic bytes, so the photo
  # probes are exercising storage rather than a string that starts with 0xFFD8.
  EVAL_JPEG = Base64.decode64(
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a" \
    "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA" \
    "AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==",
  ).freeze

  class << self
    def build!(user)
      unless Rails.env.local?
        raise "the eval world writes real records - development or test only"
      end

      sweep!
      new(user).tap(&:build!)
    end

    # Shares BUDDY_EVAL_DIR with the report, so a spec driving the harness
    # can't sweep the manifest a real run is holding.
    def manifest_path
      Rails.root.join(ENV["BUDDY_EVAL_DIR"].presence || DIR, "world.json")
    end

    # Whatever a previous run left behind. Safe to call when there's nothing.
    def sweep!
      path = manifest_path
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
        # Not a record: a row in a cached list, identified by the (order_id,
        # item_id) pair its own `destroy` matches on. `id` is not a method it
        # has, which is why nothing this ever added was being taken away again.
        order = AmazonOrder.all.find { |o| o.item_id.to_s == id.to_s }
        return false if order.nil?

        order.destroy
        AmazonOrder.commit! if AmazonOrder.respond_to?(:commit!)
      else
        # By the model's PRIMARY KEY, which is not always the `id` column: Box
        # keys on `param_key` and also HAS an `id` column, so `find_by(id:)`
        # compares the text handle the manifest recorded against a bigint,
        # finds nothing, and leaves the box standing in their real inventory.
        model  = klass.constantize
        record = model.find_by(model.primary_key => id)
        return false if record.nil?

        record.destroy!
      end
      true
    rescue StandardError => e
      warn "[eval world] couldn't remove #{row["class"]}##{row["id"]}: #{e.class}: #{e.message}"
      false
    end
  end

  attr_reader :user, :made, :reused

  def initialize(user)
    @user   = user
    @made   = []
    @reused = []
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
    prompts!
    inventory!
    photos!
    self
  end

  def teardown!
    self.class.destroy_rows(made.map(&:stringify_keys)).tap { manifest_path.delete if manifest_path.exist? }
  end

  # What got built, for the run header — a sweep that reports "0/24 preconditions
  # met" because the world silently failed to build is worse than one that says
  # which half is missing.
  def summary
    counts = made.group_by { |row| row[:class] }.transform_values(&:length).sort.map { |k, n| "#{k} x#{n}" }
    counts << "reused #{reused.length} of theirs" if reused.any?
    counts
  end

  private

  # Anything the person ALREADY has is used as it stands, and never tracked:
  # teardown must not remove a chore that was theirs before the run started.
  #
  # This is not only about the unique index that "bakkie" hit. A second "Take
  # out the recycling" standing beside their real one doesn't make "rename the
  # recycling chore" more answerable — it makes it AMBIGUOUS, and then a miss
  # gets read as a description problem when the description was fine and the
  # question had two right answers. The eval runs against their real database
  # precisely so the records are the ones they'd actually be talking about;
  # duplicating them throws that away.
  #
  # Callers look up what's there with a FRESH query rather than through
  # `user.buddy_routines`, because a has_many proxy caches the moment it's read
  # and `User.me` is memoized process-wide. Off a cached association the second
  # build of a run can't see the first build's rows, and that surfaces as a
  # unique-index violation partway through rather than as a duplicate.
  def reuse(found)
    return track(yield) if found.nil?

    @reused << found
    found
  end

  # Recorded BEFORE the next record is built, so a crash between two writes
  # still leaves the first one on the list.
  def track(record)
    @made << { class: record.class.name, id: record.id }
    manifest_path.dirname.mkpath
    manifest_path.write(JSON.pretty_generate(@made.map(&:stringify_keys)))
    record
  end

  def manifest_path
    @manifest_path ||= self.class.manifest_path
  end

  def household
    @household ||= user.chore_household
  end

  def chores!
    return if household.nil?

    live = household.chores.active.to_a
    @recycling = reuse(live.detect { |chore| chore.name.match?(/recycl/i) }) {
      Chore.create!(
        created_by_user: user, chore_household: household, name: "Take out the recycling",
        reward_pebbles: 2, recurrence: { freq: :weekly, by_day: %w[tue] }
      )
    }
    @water = reuse(live.detect { |chore| chore.name.match?(/water/i) }) {
      Chore.create!(
        created_by_user: user, chore_household: household, name: "Drink Water",
        reward_pebbles: 1, recurrence: { freq: :daily }
      )
    }
    completion!(@water)
    completion!(@recycling)
  end

  # `edit_chore_completion` and `undo_chore_completion` both need a landed
  # completion to talk about, and they are the two most often confused with
  # logging a fresh one. Theirs counts: a second one today would be a second
  # thing "that water you just marked" could mean.
  def completion!(chore)
    day = user.perceived_today
    reuse(ChoreCompletion.find_by(chore: chore, user: user, day_key: day)) {
      ChoreCompletion.create!(chore: chore, user: user, completed_at: 2.hours.ago, day_key: day)
    }
  end

  # A list belongs to people through UserList, so a NEW one needs both rows.
  # Matched on "grocer" rather than an exact name because theirs is as likely
  # to be called Grocery as Groceries, and a second list either way is the
  # ambiguity this whole file is trying not to introduce.
  def lists!
    list = user.lists.reload.detect { |l| l.name.match?(/grocer/i) }
    if list.nil?
      list = track(List.create!(name: "Groceries"))
      track(UserList.create!(user: user, list: list, is_owner: true))
    else
      @reused << list
    end

    reuse(list.list_items.detect { |item| item.name.match?(/oat milk/i) }) {
      ListItem.create!(list: list, name: "Oat milk")
    }
  end

  # Anchored to THEIR morning rather than "four hours ago". A run at 9pm put
  # these in the late afternoon, and the probe that says "I logged a Strawberry
  # Celsius by accident this morning" then correctly found nothing that
  # matched — a probe failing on the wording of its own seed.
  def events!
    { "Strawberry Celsius" => 0, "Sandwich" => 30 }.each { |name, offset|
      # A wide reuse window on purpose: a SECOND Strawberry Celsius makes "get
      # rid of the one I logged by accident" a question rather than an action,
      # and "I found two of them, which one?" is the right answer to a mess the
      # seed made.
      since  = [morning, 12.hours.ago].min
      recent = user.action_events.where(name: name).where(timestamp: since..).first
      reuse(recent) { ActionEvent.create!(user: user, name: name, timestamp: morning + offset.minutes) }
    }
  end

  # 9am their time, or an hour ago if 9am hasn't happened yet.
  def morning
    @morning ||= (
      zone  = ActiveSupport::TimeZone[user.timezone.to_s] || Time.zone
      local = Time.current.in_time_zone(zone)
      [local.change(hour: 9), local - 1.hour].min
    )
  end

  def reminders!
    convo = conversation
    return if convo.nil?

    # Reused only when it's already in THIS thread. `upcoming_reminders` is
    # conversation-scoped, so one of theirs sitting in another thread is
    # invisible here — and reusing it means the probe asks Buddy about
    # something it has no way to see, which reads as a description failure and
    # isn't one. Three probes failed exactly that way, twice.
    #
    # And when the wording exists in ANOTHER thread, nothing is built at all.
    # Adding a second "the vet appointment" gives the context one reminder and
    # the tool's fuzzy match two, so a perfectly correct "two vet reminders
    # match, which one do you want gone?" gets scored as a miss. Better to
    # leave it, and let the precondition say the thread has none.
    mine = BuddyReminder.pending.where(user: user).to_a
    {
      /tomato/i     => "water the tomatoes",
      /vet/i        => "the vet appointment",
      /flower bed/i => "water the front flower bed",
    }.each { |rx, body|
      matching = mine.select { |r| r.body.to_s.match?(rx) }
      here     = matching.detect { |r| r.byte_conversation_id == convo.id }
      next @reused << here if here
      next if matching.any?

      track(BuddyReminder.create!(user: user, byte_conversation: convo, body: body, fire_at: 6.hours.from_now))
    }
  end

  def agenda!
    agenda = user.agendas.first
    return if agenda.nil?

    upcoming = agenda.agenda_items.where(start_at: Time.current..2.weeks.from_now).to_a
    reuse(upcoming.detect { |item| item.name.to_s.match?(/dentist/i) }) {
      AgendaItem.create!(
        agenda: agenda, kind: :event, name: "Dentist",
        start_at: 1.day.from_now.change(hour: 15), end_at: 1.day.from_now.change(hour: 16)
      )
    }

    # Carries a LOCATION, and a wrong-ish one, so a correcting turn has
    # something real to move and the relay that rides on it has a place to
    # name. Prod 5057 is the probe.
    reuse(upcoming.detect { |item| item.name.to_s.match?(/family party/i) }) {
      AgendaItem.create!(
        agenda: agenda, kind: :event, name: "Family Party and TG Point",
        location: "Nyjah's Gifts",
        start_at: 3.days.from_now.change(hour: 10), end_at: 3.days.from_now.change(hour: 12)
      )
    }

    # Carries a real DRIVE TIME, which is what `leave_at` works back from. The
    # travel hash is written here rather than left to the chain service: that
    # would want a Google round-trip, and a probe about "leave at 4" only needs
    # the number to exist. 31 minutes, as agenda_items 1069 had.
    reuse(upcoming.detect { |item| item.name.to_s.match?(/orchard/i) }) {
      AgendaItem.create!(
        agenda: agenda, kind: :event, name: "Orchard for shakes",
        location: "Rowley's Red Barn", arrive_early_minutes: 0,
        start_at: 2.days.from_now.change(hour: 17), end_at: 2.days.from_now.change(hour: 18),
        metadata: { "travel" => { "travel_seconds" => 1860, "travel_minutes" => 31 } }
      )
    }

    # A REPEATING one, for the series probes. MATERIALIZE_WINDOW is 30 hours,
    # so most of its occurrences exist only as the rule - which is the whole
    # point of it being here. Its items are `dependent: :destroy`, so the
    # manifest holding the schedule is enough to take the lot back down.
    series = AgendaSchedule.where(agenda_id: agenda.id).to_a
    reuse(series.detect { |sc| sc.name.to_s.match?(/pilaf/i) }) {
      AgendaSchedule.create!(
        agenda: agenda, kind: :event, name: "Kevin's meal & pilaf",
        duration_minutes: 60, starts_on: Date.current, start_time: "18:00",
        recurrence: { "freq" => "weekly", "by_day" => ["mon"] }
      )
    }
  end

  def ideas!
    held = user.buddy_memories.kind_stash.status_active.to_a
    reuse(held.detect { |m| m.content.to_s.match?(/greenhouse/i) }) {
      # Filed under `me`, because `move_idea`'s probe asks to move it to `home`
      # and a move to where it already is is a no-op the model is right to
      # decline: "It's already in Home."
      BuddyMemory.create!(
        user: user, kind: :stash, status: :active, category: :me,
        content: "Sort out the greenhouse - the glass on the north side needs replacing"
      )
    }
  end

  # The physical inventory: a shelf, a tote on it, and two things in the tote.
  #
  # Built rather than reused, and the names are chosen to be UNAMBIGUOUS in
  # their real tree rather than merely plausible. Theirs already holds two boxes
  # called "Garage", a "Rocco Big Camping Chair" and a "Stove counter tops", and
  # a probe that says "the garage" against two of them is a question with two
  # right answers - which reads as a description failure when it is nothing of
  # the sort. `Buddy::Inventory` refuses an exact tie on purpose, so a probe
  # worded onto one would fail for being correct.
  #
  # The tote carries a photo, because `show_inventory_image` has nothing to
  # reach for without one.
  def inventory!
    # A fresh query every time, never `user.boxes` - see `reuse` above. The
    # association caches on first read and `User.me` is memoized for the life
    # of the process, so a second build in one process resolves these against
    # the FIRST build's rows and hangs the photo off a param_key that is no
    # longer in the table.
    filed = ->(name) { Box.where(user: user).detect { |box| box.name.to_s.casecmp?(name) } }

    shelf = reuse(filed.call("Attic Shelf")) { Box.create!(user: user, name: "Attic Shelf") }
    tote  = reuse(filed.call("Camping Tote")) {
      Box.create!(user: user, name: "Camping Tote", parent_key: shelf.param_key)
    }
    { "Camp Stove" => "the little green one", "Headlamp" => nil }.each { |name, note|
      reuse(filed.call(name)) {
        Box.create!(user: user, name: name, parent_key: tote.param_key, notes: note)
      }
    }

    return if BoxImage.where(box_key: tote.param_key).any?

    photo = track(BoxImage.create!(user: user, box_key: tote.param_key, caption: "packed for the season"))
    photo.file.attach(
      io: StringIO.new(EVAL_JPEG), filename: "camping-tote.jpg", content_type: "image/jpeg",
    )
  end

  # A described photo, so `find_photo` has something to find.
  #
  # Deliberately NOT the camping tote: that picture is already the subject of
  # the `show_inventory_image` probe, and a second right answer to "the photo of
  # the camping tote" would turn a description problem into an ambiguous
  # question - which then gets read as a miss.
  def photos!
    return if ImageDescription.where(user: user).exists?(["body ILIKE ?", "%router%"])

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(EVAL_JPEG), filename: "router-label.jpg", content_type: "image/jpeg",
    )
    track(blob)
    track(
      ImageDescription.create!(
        user:     user,
        blob:     blob,
        body:     "A close-up of the white label on the underside of a router, showing the model number " \
                  "and the default wifi password printed under a barcode.",
        tags:     %w[router label wifi password barcode],
        taken_at: 3.days.ago,
      ),
    )
  end

  def glossary!
    return if household.nil?

    terms = HouseholdGlossaryTerm.where(chore_household: household).to_a
    reuse(terms.detect { |t| t.term.to_s.casecmp?("bakkie") }) {
      HouseholdGlossaryTerm.create!(
        chore_household: household, term: "bakkie", meaning: "a plastic tub, not a truck",
      )
    }
  end

  # Steps have to be RUNNABLE — BuddyRoutine validates them against the
  # registry — so this is a real two-step routine rather than a placeholder.
  def routines!
    reuse(BuddyRoutine.where(user: user).detect { |r| r.name.match?(/wind.?down/i) }) {
      BuddyRoutine.create!(
        user: user, name: "Wind-down", description: "The evening one",
        steps: [
          { "tool_name" => "set_font_size", "payload" => { "size" => "normal" } },
          { "tool_name" => "set_timer", "payload" => { "minutes" => 10, "label" => "wind down" } },
        ]
      )
    }
  end

  def links!
    existing = RecordLink.where(user: user).detect { |link|
      link.source_name.match?(/coffee/i) && link.target_chore?
    }
    reuse(existing) {
      RecordLink.create!(
        user: user, source_kind: :event, source_name: "Coffee",
        target_kind: :chore, target_name: @water&.name || "Drink Water"
      )
    }
  rescue StandardError => e
    warn "[eval world] no record link: #{e.message}"
  end

  # AmazonOrder isn't an ActiveRecord model, so it can't go through `reuse` —
  # same rule by hand: theirs is left alone and only ours goes on the manifest.
  def deliveries!
    return unless Buddy::Deliveries.available?(user)

    ["desk", "mattress"].each { |name|
      next if Buddy::Deliveries.find(user, name)

      order = Buddy::Deliveries.add!(user: user, name: name, on: 3.days.from_now.to_date)
      @made << { class: "AmazonOrder", id: order.item_id }
    }
    manifest_path.write(JSON.pretty_generate(@made.map(&:stringify_keys)))
  rescue StandardError => e
    warn "[eval world] no deliveries: #{e.message}"
  end

  # The house, the printer and the camera, as the three shapes the tools
  # actually distinguish: a FUNCTION with typed args, and a bare TRIGGER.
  def jil_tasks!
    return unless defined?(Task)

    mine = Task.where(user: user, buddy_enabled: true, enabled: true).to_a
    # Matched by PATTERN, not by exact name, and this is the difference between
    # a working probe and a broken one. Their house already has a Great Fan and
    # a HASS Fan; adding a third called "Fan" doesn't give "turn the fan to low"
    # something to find, it gives it three things to choose between, and the
    # honest answer becomes a question. Theirs is also the one that would really
    # move air.
    [
      [/whisper sound/i,    "Whisper Sound",    "function(sound::String)"],
      [/camera last seen/i, "Camera Last Seen", "function(camera::String)"],
      [/fan/i,              "Great Fan",        "function(mode::String)"],
      [/chill|zen/i,        "Chill Mode",       "chill-mode"],
    ].each { |rx, name, listener|
      wanted_function = listener.start_with?("function")
      found = mine.detect { |task|
        next false unless task.name.to_s.match?(rx)

        task.listener.to_s.start_with?("function") == wanted_function
      }
      reuse(found) {
        Task.create!(
          user: user, name: name, listener: listener, buddy_enabled: true, enabled: true,
          description: "#{name}, for the eval world"
        )
      }
    }
  rescue StandardError => e
    warn "[eval world] no jil tasks: #{e.message}"
  end

  # `answer_prompt` and `skip_prompt` both need something unanswered sitting
  # there, and neither probe says anything at all without one.
  def prompts!
    reuse(user.prompts.unanswered.first) {
      # The REAL shape: `options` is an array of question hashes and
      # `answer_type` is null. A bare hash here isn't just unanswerable — it
      # took down 34 turns of a run, because `Array(a_hash)` yields pairs and
      # Buddy::Errors re-raises in development.
      Prompt.create!(
        user:     user,
        question: "Evening check-in",
        options:  [
          { "type" => "select", "question" => "How did you sleep?", "choices" => ["Badly", "Fine", "Great"], "default" => "" },
          { "type" => "text", "question" => "Anything worth noting?", "default" => "" },
        ],
      )
    }
  rescue StandardError => e
    warn "[eval world] no prompt: #{e.message}"
  end

  # Deliberately NOT here: an open question from the other companion. A relay
  # is answerable on the NEXT thing the person says and passed over after that,
  # so one built at world time is stale by the second probe — and visible to
  # the first, which is worse. `relay_answer`'s probe seeds its own, one turn
  # before it needs it. See `seed:` in lib/tasks/buddy_eval.rake.
  # Reminders and relays both hang off a thread, and a person who has never
  # opened Byte has none — which quietly skipped every reminder probe rather
  # than failing, and reported them as preconditions nobody could meet.
  # THE EVAL THREAD, not their oldest one.
  #
  # `upcoming_reminders` is scoped to the conversation on purpose (see
  # Buddy::Context) — Buddy notices the reminders in the thread it's speaking
  # in. Seeded into some other thread they're invisible, and four probes in the
  # 21 Aug run were told "I don't see a tomato reminder to move" about a
  # reminder the precondition check had just confirmed was there.
  #
  # Deliberately NOT tracked: a companion thread is furniture rather than test
  # data, the next run reuses it, and tearing one down means deleting messages
  # that BuddyUsage rows point at.
  def conversation
    @conversation ||= user.byte_conversations.evals.find_by(name: EVAL_THREAD) ||
      user.byte_conversations.create!(
        name: EVAL_THREAD, mode: :buddy, buddy_theme: "byte", metadata: { "eval" => true },
      )
  end
end
