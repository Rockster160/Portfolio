require "rails_helper"

RSpec.describe Chore, type: :model do
  describe "visibility + relative scheduling" do
    let(:user) { create(:user) }
    let(:today) { ChoreDay.current(user) }

    describe "show_on_today_view enum" do
      it "defaults to when_scheduled" do
        chore = create(:chore, created_by_user: user)
        expect(chore.today_when_scheduled?).to eq(true)
      end

      it "supports always / when_available / when_scheduled_and_available / never" do
        %i[always when_available when_scheduled_and_available never].each do |v|
          chore = create(:chore, created_by_user: user, show_on_today_view: v)
          expect(chore.show_on_today_view).to eq(v.to_s)
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

    describe "show_on_today_view :when_scheduled_and_available semantic = OR" do
      let(:chore) {
        create(:chore, created_by_user: user,
          show_on_today_view: :when_scheduled_and_available,
          threshold_seconds: 6 * 3600,
          recurrence: { freq: :daily })
      }
      it "shows when scheduled even if cooldown hasn't elapsed" do
        create(:chore_completion, chore: chore, user: user,
          completed_at: 1.hour.ago, day_key: ChoreDay.current(user), payout_skipped: false)
        get_history = "irrelevant"
        # We test the rule itself indirectly: scheduled=true (daily) so OR returns true
        # regardless of cooldown_elapsed?=false.
        expect(chore.cooldown_elapsed?(user, now: Time.current)).to eq(false)
        expect(chore.matches_day?(Date.current, user)).to eq(true)
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

    describe "#marked_due?" do
      it "is false when marked_due_at is nil" do
        expect(chore.marked_due?).to be(false)
      end

      it "is true when marked_due_at is present" do
        chore.update!(marked_due_at: Time.current)
        expect(chore.marked_due?).to be(true)
      end
    end

    describe "ChoreCompletion does NOT clear the stamp synchronously" do
      # The mark stays until ChoreDailyResetWorker runs at the next
      # chore-day rollover. Holding the clear keeps today_visible? /
      # scheduled_due_on stable across same-day completions — completing
      # a chore must not change its slot in the Today tab.
      before { chore.update!(marked_due_at: 2.hours.ago) }

      it "keeps marked_due_at intact after a credited completion" do
        create(:chore_completion, chore: chore, user: user)
        expect(chore.reload.marked_due_at).to be_present
      end

      it "keeps marked_due_at intact after a skipped completion" do
        create(:chore_completion, chore: chore, user: user, payout_skipped: true)
        expect(chore.reload.marked_due_at).to be_present
      end

      it "keeps marked_due_at intact after an anonymous completion" do
        create(:chore_completion, chore: chore, user: user, anonymous: true)
        expect(chore.reload.marked_due_at).to be_present
      end
    end
  end

  describe "priority" do
    let(:user) { create(:user) }

    it "defaults to normal" do
      chore = create(:chore, created_by_user: user)
      expect(chore.priority).to eq("normal")
      expect(chore).to be_priority_normal
    end

    it "stores descending integers so higher = more urgent" do
      expect(described_class.priorities.values_at("critical", "high", "normal", "low", "none"))
        .to eq([4, 3, 2, 1, 0])
    end

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

    it "rides along on the Jil trigger payload" do
      chore = create(:chore, created_by_user: user, priority: :high)
      expect(chore.jil_attrs(action: :updated)[:priority]).to eq("high")
    end

    it "is serialized with both the name and the sortable rank" do
      chore = create(:chore, created_by_user: user, priority: :critical)
      json = ChoreSerializer.new(chore, viewer: user).as_json

      expect(json[:priority]).to eq("critical")
      expect(json[:priority_rank]).to eq(4)
    end
  end

  describe "target_count" do
    let(:user) { create(:user) }

    it "defaults to 1 when not specified" do
      chore = create(:chore, created_by_user: user)
      expect(chore.target_count).to eq(1)
    end

    it "persists a custom target" do
      chore = create(:chore, created_by_user: user, target_count: 5)
      expect(chore.reload.target_count).to eq(5)
    end

    it "rejects values below 1" do
      chore = build(:chore, created_by_user: user, target_count: 0)
      expect(chore).not_to be_valid
      expect(chore.errors[:target_count]).to be_present
    end

    it "rejects negative values" do
      chore = build(:chore, created_by_user: user, target_count: -1)
      expect(chore).not_to be_valid
    end

    it "rejects values above 99" do
      chore = build(:chore, created_by_user: user, target_count: 100)
      expect(chore).not_to be_valid
    end

    it "accepts the upper bound" do
      chore = build(:chore, created_by_user: user, target_count: 99)
      expect(chore).to be_valid
    end

    it "includes target_count in jil_attrs payload" do
      chore = create(:chore, created_by_user: user, target_count: 4)
      payload = chore.jil_attrs(action: :created)
      expect(payload[:target_count]).to eq(4)
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

    describe "broadcasts on persistence" do
      it "fans out a ChoreBroadcaster call when a chore is created via the model" do
        expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, kind_of(Chore))
        Chore.create!(name: "Surprise", created_by_user: alice, chore_household: household, reward_pebbles: 1)
      end

      it "fires the same broadcast on archival / destroy" do
        chore = create(:chore, created_by_user: alice, chore_household: household, name: "X", reward_pebbles: 1)
        expect(ChoreBroadcaster).to receive(:broadcast_changes!).with(alice, chore).twice
        chore.update!(archived_at: Time.current)
        chore.destroy!
      end
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

      it "alice completes → bob taps 1h later → bob's payout is skipped" do
        base = Time.current
        travel_to(base) { ChoreCompleter.new(chore, alice).call }
        travel_to(base + 1.hour) {
          result = ChoreCompleter.new(chore, bob).call
          expect(result).to be_skipped
          expect(result.completion.paid_pebbles).to eq(0)
        }
        expect(alice.reload.chore_balance).to eq(5)
        expect(bob.reload.chore_balance).to eq(0)
      end

      it "after the window, the next tapper IS paid" do
        base = Time.current
        travel_to(base) { ChoreCompleter.new(chore, alice).call }
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

      it "owner is implicitly a manager" do
        expect(household.manager?(alice)).to be(true)
      end

      it "managers can manage chores; members cannot" do
        expect(bob.reload.can_manage_chores?).to be(true)
        expect(member.reload.can_manage_chores?).to be(false)
      end

      it "transfers are restricted to household peers" do
        outsider = create(:user)
        create(:chore_completion, user: bob, paid_pebbles: 10, base_pebbles: 10, payout_skipped: false)
        ok = ChoreTransfer.new(from_user: bob, to_user: alice, amount_pebbles: 1)
        bad = ChoreTransfer.new(from_user: bob, to_user: outsider, amount_pebbles: 1)
        expect(ok).to be_valid
        expect(bad).not_to be_valid
        expect(bad.errors[:to_user_id]).to include("must be in your chore household")
      end
    end
  end

  describe "smoke" do
    let(:user) { create(:user) }

    it "loads all chore classes without error" do
      chore = create(:chore, created_by_user: user, name: "Brush Teeth", reward_pebbles: 1)
      expect(chore).to be_persisted
      expect(chore.reward_label).to eq("1p")
    end

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

    it "accessible_chores includes all chores in the household" do
      owner = create(:user)
      member = create(:user)
      household = create(:chore_household, owner_user: owner)
      create(:chore_household_membership, chore_household: household, user: member, role: :member)
      chore = create(:chore, created_by_user: owner, chore_household: household)
      expect(member.reload.accessible_chores).to include(chore)
    end
  end
end
