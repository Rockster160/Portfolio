require "rails_helper"

RSpec.describe Buddy::Context do
  # Two-layer defense against silent "empty context" regressions:
  #   1. Explicit fixture setup exercises the FULL happy path against
  #      Buddy::Context.build. Any method-name typo / API drift breaks
  #      a specific assertion, same as the member_user_ids bug.
  #   2. Canary spec: assert Rails.logger receives ZERO warnings during
  #      a healthy build. Every silent rescue in Context.rb logs on
  #      failure - if a future change adds a typo in ANY builder, its
  #      rescue fires, its warning fires, this spec breaks. Catches the
  #      pattern, not the specific bug.
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

    describe ".build (populated fixtures - end to end)" do
      it "returns pending and done chores split into their own buckets" do
        ctx = described_class.build(user, conversation)

        pending_names = ctx[:chores_pending_today].map { |c| c[:name] }
        done_names    = ctx[:chores_done_today].map { |c| c[:name] }

        expect(pending_names).to include("Water plants")
        expect(pending_names).not_to include("Brush teeth")
        expect(done_names).to include("Brush teeth")
        expect(done_names).not_to include("Water plants")
      end

      it "populates the identity + time fields" do
        ctx = described_class.build(user, conversation)

        expect(ctx[:user_first_name]).to be_present
        expect(ctx[:timezone]).to eq("America/Denver")
        expect(ctx[:now_local]).to be_present
      end

      # Canary: silent-rescue detector. Every Buddy rescue funnels through
      # Buddy::Errors.report. This spec asserts .report is never called
      # during a healthy build - catches the WHOLE class of bug (typos,
      # renamed methods, API drift) at commit time. Includes rescues in
      # Context and any other builder called during Context.build.
      it "never invokes Buddy::Errors.report during a healthy build" do
        allow(Buddy::Errors).to receive(:report).and_call_original

        described_class.build(user, conversation)

        expect(Buddy::Errors).not_to have_received(:report)
      end
    end

    # Prod 3129 and 3208: told it hadn't done a thing, Buddy argued and was wrong
    # both times. The receipts are kept out of the transcript on purpose, so this
    # is the only record of its own doing it can consult.
    describe "recent_actions" do
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

      it "reports what ran, newest first, with the tool that ran it" do
        chip("Called **HASS Blinds**", at: 20.minutes.ago)
        chip("Dark monitors", at: 2.minutes.ago, tool: "mac_command")

        actions = described_class.build(user, conversation)[:recent_actions]

        expect(actions.pluck(:did)).to eq(["Dark monitors", "Called HASS Blinds"])
        expect(actions.first[:tool]).to eq("mac_command")
        expect(actions.first[:at]).to be_present
      end

      it "leaves out prose, so only things that really ran are evidence" do
        conversation.byte_messages.create!(
          user: user, direction: :inbound, state: :delivered,
          body: "Kk! Monitors are out. *click*", metadata: { "kind" => "buddy" }
        )

        expect(described_class.build(user, conversation)[:recent_actions]).to be_empty
      end

      it "does not reach back past the window, so it answers 'did you just'" do
        chip("Called **HASS Light**", at: 5.hours.ago)

        expect(described_class.build(user, conversation)[:recent_actions]).to be_empty
      end

      it "keeps a failed call, which is its own answer" do
        chip("Called **HASS TV**", at: 1.minute.ago, ok: false)

        expect(described_class.build(user, conversation)[:recent_actions].first[:ok]).to be(false)
      end

      it "is nameable through get_context, or Buddy can never ask for it" do
        expect(Buddy::GPT::ContextTool::SECTIONS).to include(:recent_actions)
      end
    end

    describe "member_user_ids regression guard" do
      it "calls a method that actually exists on ChoreHousehold" do
        expect(household).to respond_to(:member_user_ids)
        expect(household).not_to respond_to(:user_ids)
        expect(household.member_user_ids).to eq([owner.id])
      end
    end
  end

  # Buddy previously fell back to log_event because it only ever saw the
  # today/overdue/hot chore buckets. `chores_all` gives it the complete active
  # roster to match completions against.
  # A prompt whose `options` is a bare hash — 320 rows in dev carry one. It used
  # to raise inside the section, which production swallowed into an empty list
  # (their real prompts vanish silently) and development re-raised outright,
  # taking the whole turn with it.
  describe "pending_prompts with a malformed row" do
    let(:user) {
      User.create!(username: "prompt-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!")
    }
    let(:convo) { user.byte_conversations.create!(name: "T", mode: :buddy, buddy_theme: "byte") }

    it "skips the bad row and still lists the good ones" do
      Prompt.create!(user: user, question: "Broken one", options: { "choices" => %w[a b] })
      Prompt.create!(user: user, question: "Fine one", options: [{ "type" => "text", "question" => "How was it?" }])

      listed = described_class.send(:pending_prompts, user)

      expect(listed.pluck(:title)).to include("Broken one", "Fine one")
      expect(listed.detect { |p| p[:title] == "Fine one" }[:questions]).to eq(["How was it?"])
      expect(listed.detect { |p| p[:title] == "Broken one" }[:questions]).to eq([])
    end

    it "doesn't take the context build down with it" do
      Prompt.create!(user: user, question: "Broken one", options: { "choices" => %w[a b] })

      built = described_class.build(user, convo)

      expect(built[:pending_prompts].pluck(:title)).to include("Broken one")
    end
  end

  describe "chores_all" do
    it "lists every active chore (even ones not due today) and excludes archived" do
      user = create(:user)
      create(:chore, name: "Recycling Out", created_by_user: user)
      user.reload
      create(:chore, name: "Water Plants", created_by_user: user, chore_household: user.chore_household)
      archived = create(:chore, name: "Old Thing", created_by_user: user, chore_household: user.chore_household)
      archived.update!(archived_at: Time.current)

      roster = described_class.build(user, user.byte_conversations.create!(mode: :buddy))[:chores_all]

      expect(roster).to include("Recycling Out", "Water Plants")
      expect(roster).not_to include("Old Thing")
    end

    it "is an empty list for a user with no household" do
      user = create(:user)
      user.update_column(:chore_household_id, nil)
      expect(described_class.build(user, user.byte_conversations.create!(mode: :buddy))[:chores_all]).to eq([])
    end
  end

  # Personal chores credit only the person who did them; household chores count
  # if ANYONE did them. The bug: Chelsea brushing her teeth showed as Rocco's
  # teeth already done.
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

    it "does not credit a PERSONAL chore to Rocco when Chelsea did it, but DOES for a household one" do
      teeth = create(:chore, name: "Brush Teeth", chore_household: household, created_by_user: rocco, sharing_mode: :personal)
      feed  = create(:chore, name: "Feed Whisper", chore_household: household, created_by_user: rocco, sharing_mode: :household)
      ChoreDaily.create!(user: rocco, chore: teeth)
      ChoreDaily.create!(user: rocco, chore: feed)

      # Chelsea completes both today.
      create(:chore_completion, chore: teeth, user: chelsea, day_key: rocco.perceived_today)
      create(:chore_completion, chore: feed,  user: chelsea, day_key: rocco.perceived_today)

      ctx     = described_class.build(rocco, conversation)
      pending = ctx[:chores_pending_today].map { |c| c[:name] }
      done    = ctx[:chores_done_today].map { |c| c[:name] }

      expect(pending).to include("Brush Teeth")     # personal → Chelsea's doesn't count for Rocco
      expect(done).not_to include("Brush Teeth")
      expect(done).to include("Feed Whisper")       # household → anyone counts
    end

    it "credits a personal chore to Rocco when ROCCO did it" do
      teeth = create(:chore, name: "Brush Teeth", chore_household: household, created_by_user: rocco, sharing_mode: :personal)
      ChoreDaily.create!(user: rocco, chore: teeth)
      create(:chore_completion, chore: teeth, user: rocco, day_key: rocco.perceived_today)

      ctx = described_class.build(rocco, conversation)
      expect(ctx[:chores_done_today].map { |c| c[:name] }).to include("Brush Teeth")
    end

    # A shared chore counts as done the moment anyone does it, which is right -
    # but the bucket carried no actor, so the whole thing read as a list of
    # Rocco's wins. Prod 2528 congratulated him for one he hadn't touched.
    describe "who gets the credit" do
      def feed_chore!
        create(
          :chore, name: "Feed Whisper", chore_household: household,
          created_by_user: rocco, sharing_mode: :household
        ).tap { |chore| ChoreDaily.create!(user: rocco, chore: chore) }
      end

      def done_row(name)
        described_class.build(rocco, conversation)[:chores_done_today].find { |c| c[:name] == name }
      end

      it "names the housemate who actually did it" do
        create(:chore_completion, chore: feed_chore!, user: chelsea, day_key: rocco.perceived_today)

        expect(done_row("Feed Whisper")[:by]).to eq(chelsea.first_name)
      end

      it "says nothing when Rocco did it himself" do
        create(:chore_completion, chore: feed_chore!, user: rocco, day_key: rocco.perceived_today)

        expect(done_row("Feed Whisper")).not_to have_key(:by)
      end

      # Both of them tapping it is a real thing that happens, and he did do it,
      # so the credit is his to take.
      it "says nothing when they both did it" do
        feed = feed_chore!
        create(:chore_completion, chore: feed, user: chelsea, day_key: rocco.perceived_today)
        create(:chore_completion, chore: feed, user: rocco, day_key: rocco.perceived_today)

        expect(done_row("Feed Whisper")).not_to have_key(:by)
      end

      it "leaves pending chores alone" do
        feed_chore!

        pending = described_class.build(rocco, conversation)[:chores_pending_today]
        expect(pending.find { |c| c[:name] == "Feed Whisper" }).not_to have_key(:by)
      end
    end
  end

  # What order the briefing reads the pending list in.
  #
  # Aug 7: both briefings that went out named the dailies first — "Cymbalta,
  # water, teeth…" and "teeth, kitty litter, puppy feeding, water, and Wordle…" —
  # because the bucket was built `daily_ids + hot_ids + marked_today` and they
  # read straight down it. The seed says the opposite: a daily is something known
  # cold, and the thing stamped due today is the one nobody remembers.
  describe "pending chore order" do
    # Pinned to the middle of a day on purpose. A chore day runs 4am to 4am
    # (ChoreDay::CUTOFF_HOURS), so between midnight and 4 the calendar date has
    # rolled and the chore day hasn't — `Date.current` names tomorrow, every
    # `marked_due_at: Time.current` lands before the window, and the whole file
    # fails for reasons that have nothing to do with ordering. It did exactly
    # that, on an unchanged tree, at 8:41pm Mountain.
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

    it "puts a one-off stamped for today ahead of the daily habits" do
      daily("Teeth")
      daily("Water")
      due_today("Gutters")

      expect(pending_names.first).to eq("Gutters")
    end

    it "keeps the dailies rather than dropping them" do
      daily("Teeth")
      due_today("Gutters")

      expect(pending_names).to contain_exactly("Gutters", "Teeth")
      expect(pending_names.last).to eq("Teeth")
    end

    it "sorts the hot picks by how hot they are, under the due-today one" do
      due_today("Gutters")
      hot(daily("Litter"), 2)
      hot(daily("Wipe"), 5)

      expect(pending_names).to eq(%w[Gutters Wipe Litter])
    end

    # It's still the habit they know cold; the stamp only says it's on today,
    # which every daily already is.
    it "leaves a daily that is ALSO stamped for today with the dailies" do
      chore = daily("Teeth")
      chore.update!(marked_due_at: Time.current)
      due_today("Gutters")

      expect(pending_names.first).to eq("Gutters")
    end

    # Sorting wasn't enough. Aug 7 AND Aug 8 both read the dailies out in full
    # under a prompt saying at most three names, because all of them were sitting
    # right there. `chores_due_today` is the short list the briefing names from —
    # the same records, with the habits taken out.
    describe "the briefing's own list" do
      it "holds what's due today and nothing habitual" do
        daily("Teeth")
        daily("Water")
        due_today("Gutters")

        expect(due_today_names).to eq(["Gutters"])
      end

      it "counts an unusually hot pick, which is real news" do
        hot(create(:chore, name: "Litter", created_by_user: user), 5)

        expect(due_today_names).to eq(["Litter"])
      end

      it "drops a daily even when it's been pinned hot" do
        hot(daily("Wipe"), 5)

        expect(due_today_names).to be_empty
      end

      # Seven chores get auto-pinned at 2x every single morning - 144 of them in
      # the three weeks to Aug 10, against three 5x ever. So a plain 2x is the
      # rotation, not a reason to say anything. Aug 10's briefing named six of
      # them in a row; every one was a 2x pin.
      it "ignores the everyday 2x pins, which are the routine wearing a new name" do
        %w[Dishes Mail Espresso].each { |name| hot(create(:chore, name: name, created_by_user: user), 2) }

        expect(due_today_names).to be_empty
      end

      it "keeps a stamped one-off next to a big pick, and drops the 2x beside them" do
        due_today("Gutters")
        hot(create(:chore, name: "Litter", created_by_user: user), 5)
        hot(create(:chore, name: "Dishes", created_by_user: user), 2)

        expect(due_today_names).to contain_exactly("Gutters", "Litter")
      end

      # Deliberately uncapped. A ceiling was tried and either got ignored while
      # the full list sat in front of the model, or lopped the tail off a day that
      # genuinely had a lot on. Being right about what belongs here is what keeps
      # it short; if six separate one-offs really are stamped for today, six is
      # the honest answer.
      it "hands over everything that qualifies, however many that is" do
        6.times { |i| due_today("Job #{i}") }

        expect(due_today_names.length).to eq(6)
      end

      it "comes back empty on a day that's only habits, rather than reaching for one" do
        daily("Teeth")
        daily("Water")

        expect(due_today_names).to be_empty
        # The habits are still in context — they just aren't what gets named.
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
  # (User#perceived_today). Between them sits an hour where the two names
  # disagree, and the buckets are keyed the ChoreDay way throughout — completions,
  # hot picks, and the marked-due window all land a day off if the perceived date
  # is what gets passed in. Its own file-level block because it needs its own
  # clock, and travel_to doesn't nest.
  describe "Buddy chores across the 3am-to-4am seam" do
    around { |ex| travel_to(Time.find_zone("America/Denver").parse("2026-08-08 03:30")) { ex.run } }

    # User#timezone is hardcoded to America/Denver, which is what both rollovers
    # are read in — so 3:30am Denver is genuinely inside the seam.
    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

    before { user.update!(chore_household_id: household.id) }

    def daily(name)
      chore = create(:chore, name: name, created_by_user: user)
      user.chore_dailies.create!(chore: chore)
      chore
    end

    def due_today(name)
      create(:chore, name: name, created_by_user: user, marked_due_at: Time.current)
    end

    describe "which day the buckets are built for" do
      it "disagrees with the perceived date, which is the whole problem" do
        expect(user.perceived_today).to eq(Date.new(2026, 8, 8))
        expect(ChoreDay.current(user)).to eq(Date.new(2026, 8, 7))
      end

      it "still counts a chore stamped due in that hour as due, not overdue" do
        due_today("Gutters")

        buckets = Buddy::Context.send(:build_chore_buckets, user, ChoreDay.current(user))

        expect(buckets[:due_today].pluck(:name)).to eq(["Gutters"])
        expect(buckets[:overdue_backlog].pluck(:name)).to be_empty
      end

      it "sees a completion logged in that hour as done" do
        chore = daily("Teeth")
        create(:chore_completion, chore: chore, user: user)

        buckets = Buddy::Context.send(:build_chore_buckets, user, ChoreDay.current(user))

        expect(buckets[:pending_today].pluck(:name)).to be_empty
        expect(buckets[:done_today].pluck(:name)).to eq(["Teeth"])
      end

      # What the context actually hands the model, rather than what a helper
      # called directly does — the bug was entirely in which date got passed.
      it "builds the real context off the chore day" do
        due_today("Gutters")
        conversation = user.byte_conversations.create!(mode: :buddy, name: "Buddy")

        context = Buddy::Context.full(user, conversation)

        expect(context[:chores_due_today].pluck(:name)).to eq(["Gutters"])
        expect(context[:chores_overdue_backlog]).to be_empty
      end
    end
  end

  # Prod 3255. The morning after a one-off reminder rang at 7:00 PM, Suki said
  # "the swimming lesson schedule reminder is set for this evening" — the same
  # reminder, re-dated a day forward, announced as still coming.
  #
  # Nothing lied to her. `fired_at` was set, so the row left `pending` and left
  # `upcoming_reminders` with it, and the only remaining trace of that reminder
  # anywhere the model could see was the conversation itself. A transcript says a
  # reminder exists and says nothing about which day, so read as a source it is
  # permanently about the future.
  #
  # An absence can't contradict anything. So a one-off that fired stays visible
  # for two days, marked as finished rather than upcoming.
  describe "a reminder that already rang" do
    let(:user)   { create(:user) }
    let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    def reminder!(body:, fire_at:, **attrs)
      BuddyReminder.create!(user: user, byte_conversation: convo, body: body, fire_at: fire_at, **attrs)
    end

    def reminders
      Buddy::Context.build(user, convo)[:upcoming_reminders]
    end

    def find(body)
      reminders.find { |r| r[:body].to_s.include?(body) }
    end

    it "keeps a one-off that fired last night in view" do
      reminder!(body: "Check the swim schedule", fire_at: 14.hours.ago, fired_at: 14.hours.ago)

      expect(find("swim schedule")).to be_present
    end

    # The whole point: visible AND unmistakably done. Visible-but-undated would
    # reproduce the bug with an extra step.
    it "marks it finished rather than letting it read as upcoming" do
      reminder!(body: "Check the swim schedule", fire_at: 14.hours.ago, fired_at: 14.hours.ago)

      row = find("swim schedule")
      expect(row[:status]).to eq(:already_rang)
      expect(row[:rang]).to be_present
      expect(row).not_to have_key(:fire_at)
    end

    it "lets go of one that rang last week" do
      reminder!(body: "Old news", fire_at: 8.days.ago, fired_at: 8.days.ago)

      expect(find("Old news")).to be_nil
    end

    it "leaves a pending one exactly as it was" do
      reminder!(body: "Vet appt", fire_at: 2.hours.from_now)

      row = find("Vet appt")
      expect(row[:fire_at]).to be_present
      expect(row[:status]).to be_nil
    end

    # A recurring reminder never sets `fired_at` — it rolls `fire_at` forward and
    # reports `last_fired`, which is a different fix for a different shape of the
    # same lie. It must not also show up here as finished.
    it "does not double-list a recurring one that rolled forward" do
      reminder!(
        body: "Water the flower bed", fire_at: 22.hours.from_now, last_fired_at: 2.hours.ago,
        recurrence: { "kind" => "daily", "at" => "08:00" }
      )

      rows = reminders.select { |r| r[:body].to_s.include?("flower bed") }
      expect(rows.length).to eq(1)
      expect(rows.first[:last_fired]).to be_present
    end

    # How often a reminder repeats, in the same words an agenda item says it
    # in, from the same mapping. The briefing drops the everyday ones on this
    # tag (Buddy::GPT::ContextTool.without_routine_reminders) and it had no way
    # to tell them apart before, so the same standing nudges came back every
    # morning.
    describe "how often it repeats" do
      it "says daily for a daily one" do
        reminder!(body: "Do Dishes.", fire_at: 4.hours.from_now,
                  recurrence: { "freq" => "daily", "at" => "15:00" })

        expect(find("Do Dishes")[:cadence]).to eq("daily")
      end

      it "reads the legacy shape too, so a row written before the vocabularies merged still says it" do
        reminder!(body: "Grab my Loops", fire_at: 4.hours.from_now,
                  recurrence: { "kind" => "daily", "at" => "07:54" })

        expect(find("Grab my Loops")[:cadence]).to eq("daily")
      end

      it "keeps a weekly one distinguishable from a daily one" do
        reminder!(body: "Water the ferns", fire_at: 4.hours.from_now,
                  recurrence: { "freq" => "weekly", "at" => "18:00", "by_day" => ["sunday"] })

        expect(find("Water the ferns")[:cadence]).to eq("weekly (Sun)")
      end

      it "says nothing at all for a one-off" do
        reminder!(body: "Call the vet back", fire_at: 4.hours.from_now)

        expect(find("Call the vet back")).not_to have_key(:cadence)
      end
    end

    it "leaves a cancelled one to the off list rather than calling it rung" do
      reminder!(body: "Nevermind this", fire_at: 3.hours.ago, cancelled_at: 4.hours.ago)

      expect(find("Nevermind this")[:status]).to eq(:off)
    end

    # The section is only useful if the model is told what the marker means, and
    # "already delivered" is the one reading that has to be impossible to miss.
    it "tells the model that one of these is not coming" do
      expect(Buddy::Personality.for(user, conversation: convo)).to include("`status: already_rang`")
    end
  end

  # Prod 4831, 27 Aug: "send me a link to my Doctor list" came back as
  # `[Doctor!](https://ardesian.com/lists)` - the index, because `app_pages` was
  # the only place a list URL existed and it only has the index.
  describe "a list's own link" do
    let(:user) { create(:user) }

    def entry(name)
      described_class.send(:lists, user.reload).detect { |l| l[:name] == name }
    end

    def list!(name)
      List.create!(name: name).tap { |list| user.user_lists.create!(list: list, is_owner: true) }
    end

    it "carries an absolute url built from the list's id" do
      list = list!("Doctor!")

      expect(entry("Doctor!")[:url]).to eq("#{Buddy::AppPages.host}/lists/#{list.id}")
    end

    # The id rather than the slug, because a slug is derived from the name and
    # a name gets renamed - and the link is already sitting in the thread.
    it "keeps working after the list is renamed" do
      list = list!("Doctor!")
      was  = entry("Doctor!")[:url]
      list.update!(name: "Health stuff")

      expect(entry("Health stuff")[:url]).to eq(was)
    end

    # A name of pure emoji parameterizes to nothing, which as a slug would make
    # `/lists/` - the index again.
    it "handles a name that would leave no slug at all" do
      list = list!("💧")

      expect(list.parameterized_name).to be_blank
      expect(entry("💧")[:url]).to end_with("/lists/#{list.id}")
    end

    it "still carries the sections" do
      list = list!("Grocery")
      list.sections.create!(name: "Produce", color: "#ffffff")

      expect(entry("Grocery")[:sections]).to eq(["Produce"])
    end
  end
end
