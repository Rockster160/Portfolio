require "rails_helper"

RSpec.describe Chore, type: :model do
  describe "visibility + relative scheduling" do
    let(:user) { create(:user) }
    let(:today) { ChoreDay.current(user) }

    # `matches_day?` answers "can this be done today". `strictly_matches_day?`
    # answers "is today the day it comes round", which is what a briefing asks.
    describe "strictly_matches_day?" do
      def relative(interval, last_done:)
        chore = create(:chore, created_by_user: user,
          recurrence: { freq: :relative, unit: :day, interval: interval })
        create(:chore_completion, chore: chore, user: user, day_key: last_done)
        chore
      end

      it "is true on the day it comes round" do
        chore = relative(7, last_done: today - 7)

        expect(chore.matches_day?(today, user)).to eq(true)
        expect(chore.strictly_matches_day?(today, user)).to eq(true)
      end

      # The whole difference, in one example.
      it "is false once it is merely overdue, where matches_day? stays true" do
        chore = relative(7, last_done: today - 19)

        expect(chore.matches_day?(today, user)).to eq(true)
        expect(chore.strictly_matches_day?(today, user)).to eq(false)
      end

      it "is false before it is due at all" do
        chore = relative(7, last_done: today - 2)

        expect(chore.strictly_matches_day?(today, user)).to eq(false)
      end

      it "leaves a fixed recurrence exactly as matches_day? had it" do
        chore = create(:chore, created_by_user: user, recurrence: { freq: :weekly, by_day: [Chore::WEEKDAY_KEYS[today.wday]] })

        expect(chore.strictly_matches_day?(today, user)).to eq(chore.matches_day?(today, user))
      end

      describe "an after_chore follower" do
        let(:anchor) { create(:chore, created_by_user: user, recurrence: { freq: :daily }) }

        def follower(interval)
          create(:chore, created_by_user: user,
            recurrence: { freq: :after_chore, unit: :day, interval: interval, anchor_chore_id: anchor.id })
        end

        it "is true the day the anchor puts it on" do
          create(:chore_completion, chore: anchor, user: user, day_key: today)

          expect(follower(0).strictly_matches_day?(today, user)).to eq(true)
        end

        it "is false when the anchor was done days ago and it never got picked up" do
          create(:chore_completion, chore: anchor, user: user, day_key: today - 3)
          chore = follower(0)

          expect(chore.matches_day?(today, user)).to eq(true)
          expect(chore.strictly_matches_day?(today, user)).to eq(false)
        end
      end
    end

    describe "matches_day? — fixed recurrences (user-independent)" do
      it "daily — always matches" do
        chore = create(:chore, created_by_user: user, recurrence: { freq: :daily })
        expect(chore.matches_day?(today)).to eq(true)
        expect(chore.matches_day?(today - 100)).to eq(true)
      end

      it "weekdays — matches Mon-Fri only" do
        chore = create(:chore, created_by_user: user, recurrence: { freq: :weekdays })
        monday = Date.new(2026, 5, 25) # confirmed Mon
        saturday = Date.new(2026, 5, 30)
        expect(chore.matches_day?(monday)).to eq(true)
        expect(chore.matches_day?(saturday)).to eq(false)
      end

      it "custom :day — anchored on starts_on (fixed pattern, completion-independent)" do
        chore = create(:chore, created_by_user: user,
          starts_on: today,
          recurrence: { freq: :custom, interval: 5, unit: :day })
        expect(chore.matches_day?(today)).to eq(true)
        expect(chore.matches_day?(today + 1)).to eq(false)
        expect(chore.matches_day?(today + 5)).to eq(true)
        # Completion on today+1 must NOT shift the next-match — fixed schedule.
        create(:chore_completion, chore: chore, user: user, completed_at: (today + 1).to_time, day_key: today + 1)
        expect(chore.matches_day?(today + 5)).to eq(true)
        expect(chore.matches_day?(today + 6)).to eq(false)
      end
    end

    describe "matches_day? — relative (anchored on last completion for user)" do
      let(:chore) {
        create(:chore, created_by_user: user,
          starts_on: today,
          recurrence: { freq: :relative, interval: 5, unit: :day })
      }

      it "first appearance falls on starts_on when never completed" do
        expect(chore.matches_day?(today, user)).to eq(true)
        expect(chore.matches_day?(today - 1, user)).to eq(false)
      end

      it "shifts to last_completion + interval when completed" do
        create(:chore_completion, chore: chore, user: user, completed_at: today.to_time, day_key: today)
        expect(chore.matches_day?(today + 4, user)).to eq(false)
        expect(chore.matches_day?(today + 5, user)).to eq(true)
        expect(chore.matches_day?(today + 6, user)).to eq(true) # carries forward
      end

      it "is per-user — sharer's completion doesn't shift my schedule" do
        other = create(:user)
        household = share_chore_household!(other, user)
        shared = create(:chore, created_by_user: other, chore_household: household,
          starts_on: today,
          recurrence: { freq: :relative, interval: 5, unit: :day })
        create(:chore_completion, chore: shared, user: other, completed_at: today.to_time, day_key: today)

        expect(shared.matches_day?(today, user)).to eq(true)   # user has not done it
        expect(shared.matches_day?(today + 5, user)).to eq(true) # still due for user
      end

      it "supports weeks and months as units" do
        weekly = create(:chore, created_by_user: user,
          starts_on: today,
          recurrence: { freq: :relative, interval: 2, unit: :week })
        monthly = create(:chore, created_by_user: user,
          starts_on: today,
          recurrence: { freq: :relative, interval: 3, unit: :month })

        create(:chore_completion, chore: weekly, user: user, day_key: today)
        create(:chore_completion, chore: monthly, user: user, day_key: today)

        expect(weekly.matches_day?(today + 14, user)).to eq(true)
        expect(weekly.matches_day?(today + 13, user)).to eq(false)
        expect(monthly.matches_day?(today >> 3, user)).to eq(true)
        expect(monthly.matches_day?(today >> 2, user)).to eq(false)
      end
    end

    describe "monthly recurrence with nth-weekday" do
      it "matches the second Tuesday of every month" do
        chore = create(:chore, created_by_user: user,
          starts_on: Date.new(2026, 5, 12), # second Tuesday of May 2026
          recurrence: { freq: :monthly, by_set_pos: 2, by_day: ["tue"] })
        expect(chore.matches_day?(Date.new(2026, 5, 12))).to eq(true) # 2nd Tue May
        expect(chore.matches_day?(Date.new(2026, 6, 9))).to eq(true)  # 2nd Tue June
        expect(chore.matches_day?(Date.new(2026, 6, 2))).to eq(false) # 1st Tue June
      end

      it "matches the last Friday of every month" do
        chore = create(:chore, created_by_user: user,
          starts_on: Date.new(2026, 5, 29),
          recurrence: { freq: :monthly, by_set_pos: -1, by_day: ["fri"] })
        expect(chore.matches_day?(Date.new(2026, 5, 29))).to eq(true)  # last Fri May
        expect(chore.matches_day?(Date.new(2026, 5, 22))).to eq(false) # not last
        expect(chore.matches_day?(Date.new(2026, 6, 26))).to eq(true)  # last Fri June
      end
    end

    describe "cooldown_elapsed?" do
      let(:chore) { create(:chore, created_by_user: user, threshold_seconds: 6 * 3600) }

      it "true when there's no completion" do
        expect(chore.cooldown_elapsed?(user)).to eq(true)
      end

      it "false within the window, true after" do
        now = Time.current
        create(:chore_completion, chore: chore, user: user, completed_at: now - 1.hour, day_key: today)
        expect(chore.cooldown_elapsed?(user, now: now)).to eq(false)
        expect(chore.cooldown_elapsed?(user, now: now + 7.hours)).to eq(true)
      end

      it "ignores skipped-payout completions" do
        now = Time.current
        create(:chore_completion, chore: chore, user: user, completed_at: now - 1.hour, payout_skipped: true, day_key: today)
        expect(chore.cooldown_elapsed?(user, now: now)).to eq(true)
      end

      it "anonymous completions hold the cooldown like a real completion" do
        now = Time.current
        create(:chore_completion, chore: chore, user: user, completed_at: now - 1.hour,
          payout_skipped: true, anonymous: true, day_key: today,
          skipped_reason: "Marked done by someone outside the household")
        expect(chore.cooldown_elapsed?(user, now: now)).to eq(false)
        expect(chore.cooldown_elapsed?(user, now: now + 7.hours)).to eq(true)
      end
    end
  end

  describe "marked_due" do
    let(:user) { create(:user) }
    let(:chore) { create(:chore, created_by_user: user) }

    describe "ChoreCompletion does NOT clear the stamp synchronously" do
      # The mark stays until ChoreDailyResetWorker runs at the next
      # chore-day rollover. Holding the clear keeps today_visible? /
      # scheduled_due_on stable across same-day completions — completing
      # a chore must not change its slot in the Today tab.
      before { chore.update!(marked_due_at: 2.hours.ago) }

      it "keeps marked_due_at intact after a credited, skipped or anonymous completion" do
        create(:chore_completion, chore: chore, user: user)
        create(:chore_completion, chore: chore, user: user, payout_skipped: true)
        create(:chore_completion, chore: chore, user: user, anonymous: true)
        expect(chore.reload.marked_due_at).to be_present
      end
    end
  end

  describe "priority" do
    let(:user) { create(:user) }

    it "orders by the raw column with critical first" do
      none     = create(:chore, created_by_user: user, priority: :none)
      critical = create(:chore, created_by_user: user, priority: :critical)
      normal   = create(:chore, created_by_user: user, priority: :normal)

      ordered = described_class.where(id: [none, critical, normal]).order(priority: :desc).to_a
      expect(ordered).to eq([critical, normal, none])
    end

    describe ".priority_key" do
      it "normalizes casing and whitespace" do
        expect(described_class.priority_key(" Critical ")).to eq("critical")
        expect(described_class.priority_key(:high)).to eq("high")
      end

      it "returns nil for anything that isn't a level, rather than defaulting" do
        expect(described_class.priority_key("urgent")).to be_nil
        expect(described_class.priority_key("")).to be_nil
        expect(described_class.priority_key(nil)).to be_nil
      end
    end

    it "rides along on the Jil trigger payload and is serialized with its sortable rank" do
      chore = create(:chore, created_by_user: user, priority: :critical)
      json = ChoreSerializer.new(chore, viewer: user).as_json

      expect(chore.jil_attrs(action: :updated)[:priority]).to eq("critical")
      expect(json[:priority]).to eq("critical")
      expect(json[:priority_rank]).to eq(4)
    end
  end

  describe "target_count" do
    let(:user) { create(:user) }

    it "accepts 1 through 99 only", :aggregate_failures do
      { 0 => false, -1 => false, 1 => true, 99 => true, 100 => false }.each do |count, valid|
        expect(build(:chore, created_by_user: user, target_count: count).valid?).to eq(valid), count.to_s
      end
    end

    it "includes target_count in jil_attrs payload" do
      chore = create(:chore, created_by_user: user, target_count: 4)
      expect(chore.jil_attrs(action: :created)[:target_count]).to eq(4)
    end
  end

  describe "household visibility + cooldown" do
    let(:alice) { create(:user) }
    let(:bob)   { create(:user) }
    let(:carl)  { create(:user) }
    let!(:household) { create(:chore_household, owner_user: alice) }

    before do
      create(:chore_household_membership, chore_household: household, user: bob, role: :manager)
      [alice, bob].each(&:reload)
    end

    it "fans out a ChoreBroadcaster call on create, archival and destroy" do
      expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, kind_of(Chore)).exactly(3).times
      chore = Chore.create!(name: "Surprise", created_by_user: alice, chore_household: household, reward_pebbles: 1)
      chore.update!(archived_at: Time.current)
      chore.destroy!
    end

    describe "accessible_chores filtering" do
      it "personal + household with no assignee are visible to everyone in the household" do
        personal  = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :personal)
        household_chore = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :household)

        expect(alice.accessible_chores).to include(personal, household_chore)
        expect(bob.accessible_chores).to include(personal, household_chore)
        expect(carl.accessible_chores).to be_empty
      end

      it "personal + assigned hides the chore from non-assignees entirely" do
        to_alice = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :personal, assigned_to_user: alice)
        to_bob   = create(:chore, created_by_user: alice, chore_household: household, sharing_mode: :personal, assigned_to_user: bob)

        expect(alice.accessible_chores).to include(to_alice)
        expect(alice.accessible_chores).not_to include(to_bob)
        expect(bob.accessible_chores).to include(to_bob)
        expect(bob.accessible_chores).not_to include(to_alice)
      end

      it "household + assigned stays grid-visible to everyone in the household" do
        house_assigned = create(:chore,
          created_by_user: alice, chore_household: household,
          sharing_mode: :household, assigned_to_user: bob)

        expect(alice.accessible_chores).to include(house_assigned)
        expect(bob.accessible_chores).to include(house_assigned)
      end

      it "users without a household see nothing" do
        create(:chore, created_by_user: alice, chore_household: household)
        expect(carl.accessible_chores).to be_empty
        expect(carl.chore_household_user_ids).to eq([carl.id])
      end
    end

    describe "Today visibility (household + assigned)" do
      it "today_visible? is true only for the assignee" do
        chore = create(:chore,
          created_by_user: alice, chore_household: household,
          sharing_mode: :household,
          assigned_to_user: bob, show_on_today_view: :always)
        alice_view = ChoreSerializer.new(chore, viewer: alice).as_json
        bob_view   = ChoreSerializer.new(chore, viewer: bob).as_json
        expect(alice_view[:today_visible]).to be(false)
        expect(bob_view[:today_visible]).to be(true)
      end

      it "with no assignee, Today follows normal show_on_today_view rules for everyone" do
        chore = create(:chore,
          created_by_user: alice, chore_household: household,
          sharing_mode: :household, show_on_today_view: :always)
        expect(ChoreSerializer.new(chore, viewer: alice).as_json[:today_visible]).to be(true)
        expect(ChoreSerializer.new(chore, viewer: bob).as_json[:today_visible]).to be(true)
      end
    end

    describe "cooldown — household shares the timer across the group" do
      let(:chore) {
        create(:chore, created_by_user: alice, chore_household: household,
          sharing_mode: :household, reward_pebbles: 5, threshold_seconds: 6 * 3600)
      }

      it "skips bob's payout inside alice's window and pays the next tapper after it" do
        base = Time.current
        travel_to(base) { ChoreCompleter.new(chore, alice).call }
        travel_to(base + 1.hour) {
          result = ChoreCompleter.new(chore, bob).call
          expect(result).to be_skipped
          expect(result.completion.paid_pebbles).to eq(0)
        }
        expect(alice.reload.chore_balance).to eq(5)
        expect(bob.reload.chore_balance).to eq(0)

        travel_to(base + 7.hours) {
          result = ChoreCompleter.new(chore, bob).call
          expect(result).not_to be_skipped
          expect(result.completion.paid_pebbles).to eq(5)
        }
      end
    end

    describe "cooldown — personal is independent per user" do
      let(:chore) {
        create(:chore, created_by_user: alice, chore_household: household,
          sharing_mode: :personal, reward_pebbles: 5, threshold_seconds: 6 * 3600)
      }

      it "both users get paid even when they tap minutes apart" do
        base = Time.current
        travel_to(base)            { ChoreCompleter.new(chore, alice).call }
        travel_to(base + 5.minutes) { ChoreCompleter.new(chore, bob).call }
        expect(alice.reload.chore_balance).to eq(5)
        expect(bob.reload.chore_balance).to eq(5)
      end
    end

    describe "ChoreHousehold roles" do
      let(:member) { create(:user) }
      before { create(:chore_household_membership, chore_household: household, user: member, role: :member) }

      it "lets the owner and managers manage chores, and not members" do
        expect(household.manager?(alice)).to be(true)
        expect(bob.reload.can_manage_chores?).to be(true)
        expect(member.reload.can_manage_chores?).to be(false)
      end
    end
  end

  describe "households and balances" do
    let(:user) { create(:user) }

    it "ChoreDay returns date in user tz using 4am cutoff" do
      travel_to Time.zone.local(2026, 5, 28, 3, 30, 0) do
        expect(ChoreDay.current).to eq(Date.new(2026, 5, 27))
      end
      travel_to Time.zone.local(2026, 5, 28, 5, 0, 0) do
        expect(ChoreDay.current).to eq(Date.new(2026, 5, 28))
      end
    end

    it "User#chore_balance sums completions minus withdrawals" do
      create(:chore_completion, user: user, paid_pebbles: 12)
      create(:chore_completion, user: user, paid_pebbles: 5)
      create(:chore_withdrawal, user: user, amount_pebbles: 7)
      expect(user.chore_balance).to eq(10)
    end

    it "Household membership is unique per user" do
      household_a = create(:chore_household, owner_user: user)
      other = create(:user)
      create(:chore_household_membership, chore_household: household_a, user: other, role: :member)

      household_b = create(:chore_household, owner_user: create(:user))
      dup = ChoreHouseholdMembership.new(chore_household: household_b, user: other, role: :member)
      expect(dup).not_to be_valid
    end

    it "Owner gets an implicit manager membership" do
      household = create(:chore_household, owner_user: user)
      membership = household.memberships.find_by(user_id: user.id)
      expect(membership).to be_present
      expect(membership.role.to_sym).to eq(:manager)
    end
  end

  describe "#link_url" do
    let(:user) { create(:user) }

    def link_for(notes)
      build(:chore, created_by_user: user, notes: notes).link_url
    end

    it "is the first web address in the notes, without the sentence around it" do
      expect(link_for("From Cordelia · https://ardesian.com/emails/42.")).to eq("https://ardesian.com/emails/42")
      expect(link_for("(see https://example.com/a?b=1) then https://other.com")).to eq("https://example.com/a?b=1")
    end

    it "is nil when the notes carry no address" do
      expect(link_for("call the plumber")).to be_nil
      expect(link_for(nil)).to be_nil
    end
  end
end
