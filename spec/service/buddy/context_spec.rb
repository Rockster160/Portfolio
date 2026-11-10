require "rails_helper"

RSpec.describe Buddy::Context do
  describe "what a turn is handed" do
    let!(:owner) { User.create!(username: "owner-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!") }
    let!(:household) {
      ChoreHousehold.create!(owner_user: owner, name: "Test HH").tap { |h|
        owner.update!(chore_household_id: h.id)
      }
    }
    let(:user) { owner.reload }
    let(:conversation) { user.byte_conversations.create!(mode: :buddy) }
    let(:today) { user.perceived_today }

    # Two chores: one still-pending, one done today. Both dailies so
    # they land in chores_pending_today / chores_done_today.
    let!(:pending_chore) {
      Chore.create!(name: "Water plants", chore_household: household, created_by_user: owner, sharing_mode: :household, recurrence: { freq: "daily" })
    }
    let!(:done_chore) {
      Chore.create!(name: "Brush teeth", chore_household: household, created_by_user: owner, sharing_mode: :household, recurrence: { freq: "daily" })
    }
    before {
      ChoreDaily.create!(user: user, chore: pending_chore, sort_order: 0)
      ChoreDaily.create!(user: user, chore: done_chore,    sort_order: 1)
      ChoreCompletion.create!(
        user: user, chore: done_chore, completed_at: Time.current, day_key: today,
        paid_pebbles: 0, base_pebbles: 0, hot_multiplier: 1.0,
        achievement_bonus_pebbles: 0, payout_skipped: false,
      )
    }

    def chip(body, at:, tool: "call_jil_function", ok: true)
      conversation.byte_messages.create!(
        user:       user,
        direction:  :inbound,
        state:      :delivered,
        body:       body,
        created_at: at,
        metadata:   { "kind" => "buddy_activity", "tool_name" => tool, "ok" => ok },
      )
    end

    # Every Buddy rescue funnels through Buddy::Errors.report, so a healthy
    # build that reports nothing is the canary for a silently-empty section.
    #
    # `recent_actions` is the only record of its own doing Buddy can consult
    # when told it didn't do something: what ran (chips, not prose), newest
    # first, inside the window, failures included.
    it "splits pending from done, carries identity and time, recent actions, and reports no errors", :aggregate_failures do
      allow(Buddy::Errors).to receive(:report).and_call_original
      chip("Called **HASS Blinds**", at: 20.minutes.ago)
      chip("Dark monitors", at: 2.minutes.ago, tool: "mac_command")
      chip("Called **HASS TV**", at: 1.minute.ago, ok: false)
      chip("Called **HASS Light**", at: 5.hours.ago)
      conversation.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered,
        body: "Kk! Monitors are out. *click*", metadata: { "kind" => "buddy" }
      )

      ctx = described_class.build(user, conversation)

      expect(ctx[:chores_pending_today].pluck(:name)).to include("Water plants")
      expect(ctx[:chores_pending_today].pluck(:name)).not_to include("Brush teeth")
      expect(ctx[:chores_done_today].pluck(:name)).to include("Brush teeth")
      expect(ctx[:chores_done_today].pluck(:name)).not_to include("Water plants")

      expect(ctx[:user_first_name]).to be_present
      expect(ctx[:timezone]).to eq("America/Denver")
      expect(ctx[:now_local]).to be_present

      actions = ctx[:recent_actions]
      expect(actions.pluck(:did)).to eq(["Called HASS TV", "Dark monitors", "Called HASS Blinds"])
      expect(actions.first[:ok]).to be(false)
      expect(actions.second[:tool]).to eq("mac_command")
      expect(actions.second[:at]).to be_present

      expect(Buddy::Errors).not_to have_received(:report)
    end
  end

  # A prompt whose `options` is a bare hash used to raise inside the section,
  # emptying the whole list (or the whole turn in development).
  it "lists a prompt with malformed options alongside the good ones, in the full build" do
    user  = User.create!(username: "prompt-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!")
    convo = user.byte_conversations.create!(name: "T", mode: :buddy, buddy_theme: "byte")
    Prompt.create!(user: user, question: "Broken one", options: { "choices" => %w[a b] })
    Prompt.create!(user: user, question: "Fine one", options: [{ "type" => "text", "question" => "How was it?" }])

    listed = described_class.send(:pending_prompts, user)

    expect(listed.detect { |p| p[:title] == "Fine one" }[:questions]).to eq(["How was it?"])
    expect(listed.detect { |p| p[:title] == "Broken one" }[:questions]).to eq([])
    expect(described_class.build(user, convo)[:pending_prompts].pluck(:title)).to include("Broken one", "Fine one")
  end

  it "lists every active chore in chores_all, excluding archived, and nothing without a household" do
    user = create(:user)
    create(:chore, name: "Recycling Out", created_by_user: user)
    user.reload
    create(:chore, name: "Water Plants", created_by_user: user, chore_household: user.chore_household)
    archived = create(:chore, name: "Old Thing", created_by_user: user, chore_household: user.chore_household)
    archived.update!(archived_at: Time.current)

    roster = described_class.build(user, user.byte_conversations.create!(mode: :buddy))[:chores_all]

    expect(roster).to include("Recycling Out", "Water Plants")
    expect(roster).not_to include("Old Thing")

    loner = create(:user)
    loner.update_column(:chore_household_id, nil)
    expect(described_class.build(loner, loner.byte_conversations.create!(mode: :buddy))[:chores_all]).to eq([])
  end

  # Personal chores credit only the person who did them; household chores count
  # if ANYONE did them.
  describe "chore attribution" do
    let(:household) { create(:chore_household) }
    let(:rocco)     { create(:user) }
    let(:chelsea)   { create(:user) }
    let(:conversation) { rocco.byte_conversations.create!(mode: :buddy) }

    before do
      ChoreHouseholdMembership.create!(chore_household: household, user: rocco,   role: :manager)
      ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :manager)
      rocco.update_column(:chore_household_id, household.id)
      chelsea.update_column(:chore_household_id, household.id)
    end

    def chore!(name, mode)
      create(:chore, name: name, chore_household: household, created_by_user: rocco, sharing_mode: mode)
        .tap { |chore| ChoreDaily.create!(user: rocco, chore: chore) }
    end

    def done!(chore, by)
      create(:chore_completion, chore: chore, user: by, day_key: rocco.perceived_today)
    end

    # A shared chore done by somebody else names who did it, so the bucket
    # doesn't read as a list of Rocco's wins.
    it "credits a personal chore only to its doer, a household one to anyone, naming the housemate", :aggregate_failures do
      teeth = chore!("Brush Teeth", :personal)
      feed  = chore!("Feed Whisper", :household)
      chore!("Pending Shared", :household)
      done!(teeth, chelsea)
      done!(feed, chelsea)

      ctx  = described_class.build(rocco, conversation)
      done = ctx[:chores_done_today].index_by { |c| c[:name] }

      expect(ctx[:chores_pending_today].pluck(:name)).to include("Brush Teeth")
      expect(done).not_to have_key("Brush Teeth")
      expect(done["Feed Whisper"][:by]).to eq(chelsea.first_name)
      expect(ctx[:chores_pending_today].find { |c| c[:name] == "Pending Shared" }).not_to have_key(:by)
    end

    # Hers to do, so it's on her Today and nobody else's - while still being a
    # chore Rocco can be credited with by name.
    it "leaves a household chore assigned to her out of his day", :aggregate_failures do
      chore!("Feed Spiders", :household).update!(assigned_to_user_id: chelsea.id)
      chore!("Bring Cans In", :household)

      ctx = described_class.build(rocco, conversation)

      expect(ctx[:chores_pending_today].pluck(:name)).to eq(["Bring Cans In"])
      expect(ctx[:chores_all]).to include("Feed Spiders")
    end

    # Both of them tapping it is a real thing that happens, and he did do it.
    it "credits a chore to Rocco without a :by when he did it, alone or alongside her" do
      teeth = chore!("Brush Teeth", :personal)
      feed  = chore!("Feed Whisper", :household)
      done!(teeth, rocco)
      done!(feed, chelsea)
      done!(feed, rocco)

      done = described_class.build(rocco, conversation)[:chores_done_today].index_by { |c| c[:name] }

      expect(done).to have_key("Brush Teeth")
      expect(done["Brush Teeth"]).not_to have_key(:by)
      expect(done["Feed Whisper"]).not_to have_key(:by)
    end
  end

  # A daily is something known cold; the thing stamped due today is the one
  # nobody remembers, so it leads.
  describe "pending chore order" do
    # Mid-day: between midnight and 4am the chore day hasn't rolled with the
    # calendar date (ChoreDay::CUTOFF_HOURS).
    around { |ex| travel_to(Time.zone.parse("2026-08-08 15:00 UTC")) { ex.run } }

    let(:user) { create(:user) }
    let(:today) { ChoreDay.current(user) }

    def daily(name)
      chore = create(:chore, name: name, created_by_user: user)
      user.chore_dailies.create!(chore: chore)
      chore
    end

    def due_today(name)
      create(:chore, name: name, created_by_user: user, marked_due_at: Time.current)
    end

    def hot(chore, multiplier)
      ChoreHotPick.create!(chore: chore, day_key: today, multiplier: multiplier)
      chore
    end

    def buckets
      Buddy::Context.send(:build_chore_buckets, user, today)
    end

    def pending_names
      buckets[:pending_today].pluck(:name)
    end

    def due_today_names
      buckets[:due_today].pluck(:name)
    end

    # A daily also stamped for today is still a habit.
    it "puts a one-off stamped for today first, hot picks by heat, then the dailies" do
      daily("Teeth").update!(marked_due_at: Time.current)
      due_today("Gutters")
      hot(daily("Litter"), 2)
      hot(daily("Wipe"), 5)

      expect(pending_names).to eq(%w[Gutters Wipe Litter Teeth])
    end

    # `chores_due_today` is the short list the briefing names from: the same
    # records with the habits taken out. A pin is a scoring decision; it says
    # nothing about whether today is different. Deliberately uncapped.
    describe "the briefing's own list" do
      it "holds every stamped one-off, carrying its multiplier, and nothing habitual or merely pinned", :aggregate_failures do
        daily("Teeth")
        hot(daily("Wipe"), 5)
        hot(create(:chore, name: "Litter", created_by_user: user), 5)
        %w[Dishes Mail].each { |name| hot(create(:chore, name: name, created_by_user: user), 2) }
        hot(due_today("Gutters"), 2)
        5.times { |i| due_today("Job #{i}") }

        rows = buckets[:due_today]
        expect(rows.pluck(:name)).to contain_exactly("Gutters", *Array.new(5) { |i| "Job #{i}" })
        expect(rows.find { |r| r[:name] == "Gutters" }[:hot]).to eq("2x")
      end

      it "comes back empty on a day that's only habits, keeping them in pending" do
        daily("Teeth")
        daily("Water")

        expect(due_today_names).to be_empty
        expect(pending_names).to contain_exactly("Teeth", "Water")
      end

      it "leaves one out once it's done" do
        chore = due_today("Gutters")
        create(:chore_completion, chore: chore, user: user)

        expect(due_today_names).to be_empty
      end
    end
  end

  # A chore day rolls at 4am (ChoreDay), the perceived day at 3am
  # (User#perceived_today). The buckets are keyed the ChoreDay way throughout,
  # so passing the perceived date would land everything a day off.
  describe "Buddy chores across the 3am-to-4am seam" do
    around { |ex| travel_to(Time.find_zone("America/Denver").parse("2026-08-08 03:30")) { ex.run } }

    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

    before { user.update!(chore_household_id: household.id) }

    it "counts a chore stamped in that hour as due and a completion as done, in the real context too", :aggregate_failures do
      expect(user.perceived_today).to eq(Date.new(2026, 8, 8))
      expect(ChoreDay.current(user)).to eq(Date.new(2026, 8, 7))

      create(:chore, name: "Gutters", created_by_user: user, marked_due_at: Time.current)
      teeth = create(:chore, name: "Teeth", created_by_user: user)
      user.chore_dailies.create!(chore: teeth)
      create(:chore_completion, chore: teeth, user: user)

      buckets = Buddy::Context.send(:build_chore_buckets, user, ChoreDay.current(user))
      expect(buckets[:due_today].pluck(:name)).to eq(["Gutters"])
      expect(buckets[:overdue_backlog]).to be_empty
      expect(buckets[:pending_today].pluck(:name)).not_to include("Teeth")
      expect(buckets[:done_today].pluck(:name)).to eq(["Teeth"])

      context = Buddy::Context.full(user, user.byte_conversations.create!(mode: :buddy, name: "Buddy"))
      expect(context[:chores_due_today].pluck(:name)).to eq(["Gutters"])
      expect(context[:chores_overdue_backlog]).to be_empty
    end
  end

  # A chore whose SCHEDULE lands on today is named in the briefing's list,
  # unless its rhythm is every day or it sits in their daily rotation.
  describe "a chore the schedule puts on today" do
    # A Wednesday, mid-morning, well clear of the 3am-to-4am seam.
    around { |ex| travel_to(Time.find_zone("America/Denver").parse("2026-09-02 10:00")) { ex.run } }

    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

    before { user.update!(chore_household_id: household.id) }

    def scheduled(name, recurrence)
      create(:chore, name: name, created_by_user: user, chore_household: household, recurrence: recurrence)
    end

    def weekly(name)
      scheduled(name, { freq: "weekly", by_day: ["wed"] })
    end

    def buckets
      Buddy::Context.send(:build_chore_buckets, user, ChoreDay.current(user))
    end

    def due_names
      buckets[:due_today].pluck(:name)
    end

    # Only an interval of one is genuinely every day; a gap makes today
    # different from yesterday.
    it "names weekly, every-other-day and slower rhythms, and leaves the everyday ones out" do
      weekly("Take out trash bags")
      scheduled("Laundry", { freq: "relative", unit: "day", interval: 2 })
      scheduled("Trim Kitty Nails", { freq: "relative", unit: "week", interval: 2 })
      scheduled("Kitty Litter", { freq: "daily" })
      scheduled("Wash Water Bowls", { freq: "weekdays" })
      scheduled("Spray spiders", { freq: "relative", unit: "day", interval: 1 })

      expect(due_names).to contain_exactly("Take out trash bags", "Laundry", "Trim Kitty Nails")
    end

    # ChoreDaily is the person's own answer to "what do I do every day", so
    # how the row recurs doesn't matter, and nor does a hot pick on it.
    it "leaves a chore in their daily rotation out however it recurs, even as the biggest hot pick" do
      chore = weekly("Wordle")
      user.chore_dailies.create!(chore: chore)
      ChoreHotPick.create!(chore: chore, day_key: ChoreDay.current(user), multiplier: 5.0)

      expect(due_names).to be_empty
    end

    # A plain 2x is not news on its own, and a Tuesday-only chore on a Tuesday
    # is; a chore that is both must not fall between them.
    it "names a pinned one whose day this is, and not a pinned one whose day it isn't" do
      today = ChoreDay.current(user)
      mail  = scheduled("Go get mail", { freq: "weekly", by_day: [today.strftime("%a").downcase] })
      bins  = scheduled("Bins tomorrow", { freq: "weekly", by_day: [(today + 1).strftime("%a").downcase] })
      [mail, bins].each { |chore| ChoreHotPick.create!(chore: chore, day_key: today, multiplier: 2.0) }

      expect(due_names).to include("Go get mail")
      expect(due_names).not_to include("Bins tomorrow")
    end

    # `matches_day?` answers `date >= due_on` for relative and after_chore
    # schedules, so anything left undone would match every morning; it belongs
    # in the backlog, and the due_today flag on every row has to be true of it.
    describe "a chore that has been due since some earlier day" do
      def relative_chore(name, interval, last_done:)
        chore = scheduled(name, { freq: "relative", unit: "day", interval: interval })
        create(:chore_completion, chore: chore, user: user, day_key: last_done)
        chore
      end

      it "names and stamps one that comes round exactly today" do
        relative_chore("Refill Softener Salt", 7, last_done: ChoreDay.current(user) - 7)

        expect(due_names).to include("Refill Softener Salt")
        expect(buckets[:due_today].first[:due_today]).to eq(true)
      end

      it "moves one that has been due for days to the backlog, unstamped", :aggregate_failures do
        relative_chore("Refill Softener Salt", 7, last_done: ChoreDay.current(user) - 19)
        b = buckets

        expect(b[:due_today]).to be_empty
        expect(b[:overdue_backlog].pluck(:name)).to include("Refill Softener Salt")
        expect(b[:scheduled_today].pluck(:name)).to be_empty
        expect(b[:all_names]).to include("Refill Softener Salt")
        expect(b.values_at(:scheduled_today, :overdue_backlog, :pending_today).flatten.map { |row| row[:due_today] })
          .to all(be_falsey)
      end

      it "names a follower whose anchor came due today, but not one whose anchor was done earlier" do
        anchor = weekly("Take out trash bags")
        create(:chore_completion, chore: anchor, user: user, day_key: ChoreDay.current(user))
        scheduled("Bring trash cans in", { freq: "after_chore", unit: "day", interval: 0, anchor_chore_id: anchor.id })
        expect(due_names).to include("Bring trash cans in")

        old_anchor = weekly("Gather recycling")
        create(:chore_completion, chore: old_anchor, user: user, day_key: ChoreDay.current(user) - 3)
        scheduled("Bring bins in", { freq: "after_chore", unit: "day", interval: 1, anchor_chore_id: old_anchor.id })
        expect(due_names).not_to include("Bring bins in")
      end

      # A stamp is a person deciding, so the window it falls in is the whole test.
      it "leaves out one stamped due weeks ago" do
        create(:chore, name: "Trim Kitty Nails", created_by_user: user, chore_household: household,
          marked_due_at: 19.days.ago)

        expect(due_names).to be_empty
      end
    end

    # The shared noun IS the job ("it's trash day"); the ids are kept because
    # they are what `complete_chore` matches on. A verb is not a job.
    it "groups the bin run into trash and recycling, keeping every chore and id" do
      ["Gather trash", "Take out trash bags", "Take trash cans out", "Gather recycling", "Take out recycling"]
        .each { |name| weekly(name) }

      rows   = buckets[:due_today]
      groups = rows.group_by { |row| row[:group] }.transform_values { |rs| rs.pluck(:name).sort }

      expect(groups).to eq(
        "trash"     => ["Gather trash", "Take out trash bags", "Take trash cans out"],
        "recycling" => ["Gather recycling", "Take out recycling"],
      )
      expect(rows.pluck(:id).compact.uniq.length).to eq(5)
    end

    it "doesn't group on what you do, only on what it's about" do
      weekly("Take out trash bags")
      weekly("Take the dog out")

      expect(buckets[:due_today].filter_map { |row| row[:group] }).to be_empty
    end
  end

  # A one-off that fired stays visible for two days, marked finished: an
  # absence leaves the transcript as the only source, and a transcript says a
  # reminder exists without saying which day.
  describe "upcoming_reminders" do
    let(:user)   { create(:user) }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    def reminder!(body:, fire_at:, **attrs)
      BuddyReminder.create!(user: user, byte_conversation: convo, body: body, fire_at: fire_at, **attrs)
    end

    # A recurring reminder never sets `fired_at` — it rolls `fire_at` forward
    # and reports `last_fired` — so it must not also show as finished.
    it "marks a recent one-off as already rang, drops a stale one, and leaves pending, recurring and cancelled rows as they are", :aggregate_failures do
      reminder!(body: "Check the swim schedule", fire_at: 14.hours.ago, fired_at: 14.hours.ago)
      reminder!(body: "Old news", fire_at: 8.days.ago, fired_at: 8.days.ago)
      reminder!(body: "Vet appt", fire_at: 2.hours.from_now)
      reminder!(
        body: "Water the flower bed", fire_at: 22.hours.from_now, last_fired_at: 2.hours.ago,
        recurrence: { "kind" => "daily", "at" => "08:00" }
      )
      reminder!(body: "Nevermind this", fire_at: 3.hours.ago, cancelled_at: 4.hours.ago)

      rows  = described_class.build(user, convo)[:upcoming_reminders]
      named = rows.group_by { |r| r[:body] }

      swim = named["Check the swim schedule"].first
      expect(swim[:status]).to eq(:already_rang)
      expect(swim[:rang]).to be_present
      expect(swim).not_to have_key(:fire_at)

      expect(named).not_to have_key("Old news")

      vet = named["Vet appt"].first
      expect(vet[:fire_at]).to be_present
      expect(vet[:status]).to be_nil

      expect(named["Water the flower bed"].length).to eq(1)
      expect(named["Water the flower bed"].first[:last_fired]).to be_present

      expect(named["Nevermind this"].first[:status]).to eq(:off)
    end

    # The same words an agenda item uses, from the same mapping; the briefing
    # drops the everyday ones on this tag.
    it "tags how often each repeats, legacy shape included, and a one-off not at all", :aggregate_failures do
      reminder!(body: "Do Dishes.", fire_at: 4.hours.from_now, recurrence: { "freq" => "daily", "at" => "15:00" })
      reminder!(body: "Grab my Loops", fire_at: 4.hours.from_now, recurrence: { "kind" => "daily", "at" => "07:54" })
      reminder!(body: "Water the ferns", fire_at: 4.hours.from_now,
                recurrence: { "freq" => "weekly", "at" => "18:00", "by_day" => ["sunday"] })
      reminder!(body: "Call the vet back", fire_at: 4.hours.from_now)

      rows = described_class.build(user, convo)[:upcoming_reminders].index_by { |r| r[:body] }

      expect(rows["Do Dishes."][:cadence]).to eq("daily")
      expect(rows["Grab my Loops"][:cadence]).to eq("daily")
      expect(rows["Water the ferns"][:cadence]).to eq("weekly (Sun)")
      expect(rows["Call the vet back"]).not_to have_key(:cadence)
    end
  end

  # The full listener says what the task filters on; a derived `scope` beside
  # it only ever repeated a prefix of it.
  it "ships each Jil trigger's full listener and nothing derived from it" do
    user = create(:user)
    Task.create!(user: user, name: "Transactions", listener: "event:add name::Transaction", code: "", buddy_enabled: true)
    Task.create!(user: user, name: "Good Morning", listener: "goodMorning", code: "", buddy_enabled: true)

    entries = described_class.send(:jil_triggers, user.reload).index_by { |t| t[:name] }

    expect(entries["Transactions"][:listener]).to eq("event:add name::Transaction")
    expect(entries["Transactions"]).not_to have_key(:scope)
    expect(entries["Good Morning"].values).to contain_exactly(entries["Good Morning"][:id], "Good Morning", "goodMorning")
  end

  # ONE absolute template for the section rather than a url per row, filled
  # by id: a slug is derived from a name that gets renamed, and a pure-emoji
  # name parameterizes to nothing.
  describe "a list's own link" do
    let(:user) { create(:user) }

    def section
      described_class.send(:lists, user.reload)
    end

    def entry(name)
      section[:items].detect { |l| l[:name] == name }
    end

    def list!(name)
      List.create!(name: name).tap { |list| user.user_lists.create!(list: list, is_owner: true) }
    end

    it "is one absolute url template, filled by a rename-proof id, with sections and no per-row url", :aggregate_failures do
      water   = list!("💧")
      grocery = list!("Grocery")
      grocery.sections.create!(name: "Produce", color: "#ffffff")

      expect(section[:url]).to eq("#{Buddy::AppPages.host}/lists/{id}")
      expect(section[:url]).to start_with("http")
      expect(water.parameterized_name).to be_blank
      expect(entry("💧")[:id]).to eq(water.id)
      expect(entry("Grocery")[:sections]).to eq(["Produce"])
      expect(entry("Grocery")).not_to have_key(:url)

      water.update!(name: "Water log")
      expect(entry("Water log")[:id]).to eq(water.id)
    end
  end

  # `label` is the bare chore name; what tells one row from another is on
  # `sublabel`, and a level-2 row's status says it already HAPPENED.
  describe "what a live proposal row says about itself" do
    let(:user) { create(:user) }
    let(:conversation) { user.byte_conversations.create!(mode: :buddy) }

    def button(**overrides)
      {
        "id"        => 1,
        "label"     => "Take trash cans out",
        "sublabel"  => "credited to Wren\nat yesterday 2 pm",
        "tool_name" => "complete_chore",
        "status"    => "executed",
      }.merge(overrides)
    end

    def rows(*buttons)
      ByteAction.create!(
        user:              user,
        byte_conversation: conversation,
        kind:              :custom,
        tool_name:         "buddy_proposals",
        multi_select:      true,
        buttons:           buttons,
        expires_at:        1.day.from_now,
      )
      described_class.send(:active_proposals, conversation.reload)
    end

    it "carries the detail and whether the row ran or was unticked" do
      row = rows(button, button("id" => 2, "status" => "undone")).first

      expect(row[:detail]).to eq("credited to Wren\nat yesterday 2 pm")
      expect(row[:status]).to eq("executed")
      expect(rows(button("status" => "undone")).last[:status]).to eq("undone")
    end

    it "leaves the keys off entirely when a row has neither" do
      row = rows(button("sublabel" => nil, "status" => nil)).first

      expect(row).not_to have_key(:detail)
      expect(row).not_to have_key(:status)
      expect(row[:summary]).to eq("Take trash cans out")
    end
  end
end
