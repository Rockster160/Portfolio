require "rails_helper"

RSpec.describe ChoreSerializer, type: :serializer do
  let(:user)  { create(:user) }
  let(:chore) {
    create(
      :chore, created_by_user: user, name: "Brush Teeth",
      short_name: "Brush", icon: "🪥", reward_pebbles: 1,
      threshold_seconds: 3600
    )
  }

  it "emits the canonical contract that ChoreStore reads" do
    json = described_class.new(chore, viewer: user).as_json
    expect(json).to include(
      id:                chore.id,
      name:              "Brush Teeth",
      short_name:        "Brush",
      icon:              "🪥",
      reward_pebbles:    1,
      threshold_seconds: 3600,
      cooldown_kind:     :fixed,
      icon_kind:         :emoji,
      done_count_today:  0,
      hot_multiplier:    nil,
    )
  end

  it "icon_kind detects image / svg / empty" do
    image = create(:chore, created_by_user: user, icon: "data:image/png;base64,iVBOR")
    svg   = create(:chore, created_by_user: user, icon: "<svg></svg>")
    blank = create(:chore, created_by_user: user, icon: nil)
    expect(described_class.new(image, viewer: user).as_json[:icon_kind]).to eq(:image)
    expect(described_class.new(svg,   viewer: user).as_json[:icon_kind]).to eq(:svg)
    expect(described_class.new(blank, viewer: user).as_json[:icon_kind]).to eq(:empty)
  end

  it "cooldown_kind maps the sentinel to :day_reset" do
    day_reset = create(:chore, created_by_user: user, threshold_seconds: Chore::THRESHOLD_DAY_RESET)
    none      = create(:chore, created_by_user: user, threshold_seconds: nil)
    expect(described_class.new(day_reset, viewer: user).as_json[:cooldown_kind]).to eq(:day_reset)
    expect(described_class.new(none,      viewer: user).as_json[:cooldown_kind]).to eq(:none)
  end

  it "ChoreSerializerContext bulk-load yields the same payload as the lone serializer" do
    ChoreCompleter.new(chore, user).call
    ctx = ChoreSerializerContext.for_user(user)
    via_ctx = described_class.new(chore, viewer: user, ctx: ctx).as_json
    via_lone = described_class.new(chore, viewer: user).as_json
    # done_count_today is the per-viewer derived field that must agree.
    expect(via_ctx[:done_count_today]).to eq(via_lone[:done_count_today])
    expect(via_ctx[:last_completed_at]).to eq(via_lone[:last_completed_at])
  end

  describe "on_dailies" do
    it "is false when the viewer has not pinned the chore" do
      json = described_class.new(chore, viewer: user).as_json
      expect(json[:on_dailies]).to be(false)
    end

    it "is true when the viewer has pinned the chore — bulk path" do
      ChoreDaily.create!(user: user, chore: chore, sort_order: 0)
      ctx = ChoreSerializerContext.for_user(user)
      expect(described_class.new(chore, viewer: user, ctx: ctx).as_json[:on_dailies]).to be(true)
    end

    it "is true when the viewer has pinned the chore — lone path" do
      ChoreDaily.create!(user: user, chore: chore, sort_order: 0)
      expect(described_class.new(chore, viewer: user).as_json[:on_dailies]).to be(true)
    end
  end

  # ----------------------------------------------------------------
  # today_visible lock-in contract — the chore's membership on Today
  # is decided AS-OF day start, then frozen for the rest of the day.
  # Completing a chore must NEVER add it to Today; completing it must
  # NEVER remove it. The only inputs are the chore's schedule + the
  # state of paid completions strictly before `day`.
  # ----------------------------------------------------------------
  describe "today_visible is invariant to today's completions" do
    let(:today) { ChoreDay.current(user) }

    def render(c)
      described_class.new(c, viewer: user, ctx: ChoreSerializerContext.for_user(user)).as_json
    end

    it ":when_scheduled — Grid-only (not scheduled today) stays off after completion" do
      grid_only = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :never }
      )
      expect(render(grid_only)[:today_visible]).to be(false)
      ChoreCompleter.new(grid_only, user).call
      expect(render(grid_only)[:today_visible]).to be(false)
    end

    it ":when_scheduled — scheduled today stays on after completion" do
      scheduled = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :daily }
      )
      expect(render(scheduled)[:today_visible]).to be(true)
      ChoreCompleter.new(scheduled, user).call
      expect(render(scheduled)[:today_visible]).to be(true)
    end

    it ":when_available — cooldown active at day-start stays off after completion" do
      # Completed yesterday well within an 8h cooldown — at 4am today
      # the cooldown is still active, so the chore is NOT on Today.
      # Tapping it from Grid (skipped payout, but still a completion)
      # must not move it onto Today.
      ch = create(
        :chore, created_by_user: user, show_on_daily_view: :when_available,
        threshold_seconds: 8.hours.to_i, recurrence: { freq: :never }
      )
      create(
        :chore_completion, chore: ch, user: user, paid_pebbles: 1,
        completed_at: 2.hours.ago, day_key: today - 1
      )
      expect(render(ch)[:today_visible]).to be(false)
      ChoreCompleter.new(ch, user).call
      expect(render(ch)[:today_visible]).to be(false)
    end

    it ":when_available — cooldown elapsed at day-start stays on after completion" do
      # Yesterday's completion is long past its 4h cooldown. Chore is
      # on Today at 4am. Completing it (which re-engages cooldown)
      # must not flip it off — the membership decision is locked.
      ch = create(
        :chore, created_by_user: user, show_on_daily_view: :when_available,
        threshold_seconds: 4.hours.to_i, recurrence: { freq: :never }
      )
      create(
        :chore_completion, chore: ch, user: user, paid_pebbles: 1,
        completed_at: 24.hours.ago, day_key: today - 1
      )
      expect(render(ch)[:today_visible]).to be(true)
      ChoreCompleter.new(ch, user).call
      expect(render(ch)[:today_visible]).to be(true)
    end

    it "payment status doesn't affect visibility — a skipped completion " \
       "before today behaves the same as a paid one" do
         # Two identical chores, one with a PAID completion yesterday,
         # one with a SKIPPED completion yesterday. today_visible? must
         # agree — payment is a payout concern, not a visibility one.
         paid_ch = create(
           :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
           recurrence: { freq: :daily }
         )
         skipped_ch = create(
           :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
           recurrence: { freq: :daily }
         )
         create(
           :chore_completion, chore: paid_ch, user: user, paid_pebbles: 1,
           completed_at: 6.hours.ago, day_key: today - 1, payout_skipped: false
         )
         create(
           :chore_completion, chore: skipped_ch, user: user, paid_pebbles: 0,
           completed_at: 6.hours.ago, day_key: today - 1, payout_skipped: true
         )
         expect(render(paid_ch)[:today_visible]).to eq(render(skipped_ch)[:today_visible])
       end

    it "household carryover uses HOUSEHOLD-wide completion days, not just viewer's" do
      # Chelsea bug: "Get the Mail" is a weekly household chore due
      # Tuesday. Rocco completes it Tuesday. On Wednesday morning,
      # Chelsea's Today must NOT show it as a carryover overdue.
      other = create(:user)
      share_chore_household!(user, other)
      tue = Date.new(2026, 6, 2) # arbitrary Tuesday
      wed = tue + 1
      ch = create(
        :chore, created_by_user: user, sharing_mode: :household,
        show_on_daily_view: :when_scheduled,
        recurrence: { freq: :weekly, by_day: [:tue] }, starts_on: tue - 7
      )
      # Rocco completed it on Tuesday
      create(
        :chore_completion, chore: ch, user: other, paid_pebbles: 1,
        completed_at: tue.to_time + 12.hours, day_key: tue, payout_skipped: false
      )

      # Chelsea looks at Today on Wednesday.
      ctx = ChoreSerializerContext.for_user(user, day: wed)
      json = described_class.new(ch, viewer: user, ctx: ctx, day: wed).as_json
      expect(json[:today_visible]).to be(false)
    end

    it "anonymous completions count toward household carryover satisfaction" do
      # If a household chore is recorded as ANONYMOUSLY completed
      # Tuesday (neighbor brought cans), the chore should NOT carry
      # over to Wednesday for either household member — the work was
      # done.
      tue = Date.new(2026, 6, 2)
      wed = tue + 1
      ch = create(
        :chore, created_by_user: user, sharing_mode: :household,
        show_on_daily_view: :when_scheduled,
        recurrence: { freq: :weekly, by_day: [:tue] }, starts_on: tue - 7
      )
      create(
        :chore_completion, chore: ch, user: user, paid_pebbles: 0,
        completed_at: tue.to_time + 12.hours, day_key: tue,
        payout_skipped: true, anonymous: true
      )

      ctx = ChoreSerializerContext.for_user(user, day: wed)
      json = described_class.new(ch, viewer: user, ctx: ctx, day: wed).as_json
      expect(json[:today_visible]).to be(false)
    end

    it "anonymous completions DO bump done_count_today (so the ring shows)" do
      ch = create(:chore, created_by_user: user, reward_pebbles: 5)
      create(
        :chore_completion, chore: ch, user: user, paid_pebbles: 0,
        completed_at: 1.hour.ago, day_key: today,
        payout_skipped: true, anonymous: true
      )
      json = render(ch)
      # Card paints as "done" — the work was done, just not by a
      # household member. The grey ring (last_actor_anonymous) tells
      # the user nobody got credit.
      expect(json[:done_count_today]).to eq(1)
      expect(json[:last_actor_anonymous]).to be(true)
      expect(json[:last_actor_username]).to be_nil
    end

    it "a credited completion AFTER an anonymous one paints the credited actor's ring" do
      ch = create(:chore, created_by_user: user, reward_pebbles: 5)
      create(
        :chore_completion, chore: ch, user: user, paid_pebbles: 0,
        completed_at: 2.hours.ago, day_key: today,
        payout_skipped: true, anonymous: true
      )
      create(
        :chore_completion, chore: ch, user: user, paid_pebbles: 5,
        completed_at: 1.hour.ago, day_key: today, payout_skipped: false
      )
      json = render(ch)
      expect(json[:last_actor_anonymous]).to be(false)
      expect(json[:last_actor_username]).to eq(user.username)
    end

    it "due_today: daily-recurring chore is due today" do
      ch = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :daily }
      )
      expect(render(ch)[:due_today]).to be(true)
    end

    it "due_today: weekly chore matching today's weekday is due today" do
      key = AgendaSchedule::WEEKDAY_KEYS[today.wday]
      ch = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :weekly, by_day: [key] }
      )
      expect(render(ch)[:due_today]).to be(true)
    end

    it "due_today: weekly chore NOT matching today is overdue, not due today" do
      # Use yesterday's weekday so today is "carryover" via scheduled_or_carried.
      key = AgendaSchedule::WEEKDAY_KEYS[(today - 1).wday]
      ch = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :weekly, by_day: [key] }
      )
      expect(render(ch)[:today_visible]).to be(true)
      expect(render(ch)[:due_today]).to be(false)
    end

    it "due_today: one-off with starts_on == today is due today" do
      ch = create(
        :chore, created_by_user: user, one_off: true,
        show_on_daily_view: :when_scheduled, recurrence: { freq: :never },
        starts_on: today
      )
      expect(render(ch)[:today_visible]).to be(true)
      expect(render(ch)[:due_today]).to be(true)
    end

    it "due_today: one-off with starts_on in the past is overdue, not due today" do
      ch = create(
        :chore, created_by_user: user, one_off: true,
        show_on_daily_view: :when_scheduled, recurrence: { freq: :never },
        starts_on: today - 5
      )
      expect(render(ch)[:today_visible]).to be(true)
      expect(render(ch)[:due_today]).to be(false)
    end

    it "due_today: one-off without starts_on is not flagged due today" do
      ch = create(
        :chore, created_by_user: user, one_off: true,
        show_on_daily_view: :when_scheduled, recurrence: { freq: :never },
        starts_on: nil
      )
      expect(render(ch)[:today_visible]).to be(true)
      expect(render(ch)[:due_today]).to be(false)
    end

    it "due_today: relative chore is due today on its due_on date, overdue after" do
      # Last completed exactly `interval` days ago → due_on == today
      on_due_day = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :relative, interval: 3, unit: :day }
      )
      create(
        :chore_completion, chore: on_due_day, user: user, paid_pebbles: 1,
        completed_at: 3.days.ago, day_key: today - 3
      )
      expect(render(on_due_day)[:due_today]).to be(true)

      # Last completed earlier → due_on was in the past → overdue today
      overdue_rel = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :relative, interval: 3, unit: :day }
      )
      create(
        :chore_completion, chore: overdue_rel, user: user, paid_pebbles: 1,
        completed_at: 5.days.ago, day_key: today - 5
      )
      expect(render(overdue_rel)[:today_visible]).to be(true)
      expect(render(overdue_rel)[:due_today]).to be(false)
    end

    describe ":after_chore (cross-chore relative recurrence)" do
      let(:anchor) {
        create(:chore, created_by_user: user, name: "Laundry",
          show_on_daily_view: :when_scheduled, recurrence: { freq: :never })
      }
      let(:follower_recurrence) {
        { freq: :after_chore, anchor_chore_id: anchor.id, interval: 0, unit: :day }
      }

      def follower(opts = {})
        create(:chore, {
          created_by_user: user, name: "Fold Laundry",
          show_on_daily_view: :when_scheduled,
          recurrence: follower_recurrence,
        }.merge(opts))
      end

      it "anchor never completed → follower not visible" do
        f = follower
        expect(render(f)[:today_visible]).to be(false)
        expect(render(f)[:due_today]).to be(false)
      end

      it "anchor completed today + no follower completion → due today (Today section)" do
        f = follower
        create(:chore_completion, chore: anchor, user: user, paid_pebbles: 1,
          completed_at: 2.hours.ago, day_key: today)
        expect(render(f)[:today_visible]).to be(true)
        expect(render(f)[:due_today]).to be(true)
      end

      it "anchor completed yesterday + no follower completion → Scheduled carryover, not due today" do
        f = follower
        create(:chore_completion, chore: anchor, user: user, paid_pebbles: 1,
          completed_at: 1.day.ago, day_key: today - 1)
        expect(render(f)[:today_visible]).to be(true)
        expect(render(f)[:due_today]).to be(false)
      end

      it "offset 1 day: anchor done today → follower NOT visible today (surfaces tomorrow)" do
        f = follower(recurrence: follower_recurrence.merge(interval: 1))
        create(:chore_completion, chore: anchor, user: user, paid_pebbles: 1,
          completed_at: 2.hours.ago, day_key: today)
        expect(render(f)[:today_visible]).to be(false)
      end

      it "offset 1 day: anchor done yesterday → follower visible today" do
        f = follower(recurrence: follower_recurrence.merge(interval: 1))
        create(:chore_completion, chore: anchor, user: user, paid_pebbles: 1,
          completed_at: 1.day.ago, day_key: today - 1)
        expect(render(f)[:today_visible]).to be(true)
        expect(render(f)[:due_today]).to be(true)
      end

      it "anonymous anchor completion does not surface follower" do
        f = follower
        create(:chore_completion, chore: anchor, user: user,
          completed_at: 2.hours.ago, day_key: today, anonymous: true,
          payout_skipped: true, paid_pebbles: 0, skipped_reason: :anonymous_credit)
        expect(render(f)[:today_visible]).to be(false)
      end

      it "follower completed today after anchor → stays visible today (B's mid-day completion never removes)" do
        f = follower
        create(:chore_completion, chore: anchor, user: user, paid_pebbles: 1,
          completed_at: 2.hours.ago, day_key: today)
        ChoreCompleter.new(f, user).call
        expect(render(f)[:today_visible]).to be(true)
      end

      it "follower completed yesterday + anchor older → not visible today" do
        f = follower
        create(:chore_completion, chore: anchor, user: user, paid_pebbles: 1,
          completed_at: 3.days.ago, day_key: today - 3)
        create(:chore_completion, chore: f, user: user, paid_pebbles: 1,
          completed_at: 1.day.ago, day_key: today - 1)
        expect(render(f)[:today_visible]).to be(false)
      end

      it "save with self-anchor is rejected" do
        # Build a chore and try to point its anchor at itself.
        c = create(:chore, created_by_user: user, name: "X",
          recurrence: { freq: :never })
        c.recurrence = { freq: :after_chore, anchor_chore_id: c.id, interval: 0, unit: :day }
        expect(c).not_to be_valid
        expect(c.errors[:recurrence].join).to include("itself")
      end

      it "save with cross-household anchor is rejected" do
        other_user = create(:user)
        other_household = create(:chore_household)
        ChoreHouseholdMembership.create!(user: other_user, chore_household: other_household)
        other_user.update_columns(chore_household_id: other_household.id)
        external = create(:chore, created_by_user: other_user,
          chore_household: other_household, recurrence: { freq: :never })
        c = build(:chore, created_by_user: user, name: "Cross",
          recurrence: { freq: :after_chore, anchor_chore_id: external.id, interval: 0, unit: :day })
        expect(c).not_to be_valid
        expect(c.errors[:recurrence].join).to include("household")
      end

      it "save creating a cycle (A→B→A) is rejected" do
        a = create(:chore, created_by_user: user, name: "A", recurrence: { freq: :never })
        b = create(:chore, created_by_user: user, name: "B",
          recurrence: { freq: :after_chore, anchor_chore_id: a.id, interval: 0, unit: :day })
        a.recurrence = { freq: :after_chore, anchor_chore_id: b.id, interval: 0, unit: :day }
        expect(a).not_to be_valid
        expect(a.errors[:recurrence].join).to include("cycle")
      end
    end

    it ":when_scheduled — carryover survives a completion made today" do
      # Scheduled every 3 days, last appeared 2 days ago, never
      # completed. It's "carried over" to today. A completion made
      # today closes out the carryover, but today_visible must not
      # flip — Today is locked once we're inside it.
      starts_on = today - 2
      ch = create(
        :chore, created_by_user: user, show_on_daily_view: :when_scheduled,
        recurrence: { freq: :custom, every: 3, unit: :day }, starts_on: starts_on
      )
      expect(render(ch)[:today_visible]).to be(true)
      ChoreCompleter.new(ch, user).call
      expect(render(ch)[:today_visible]).to be(true)
    end
  end

end
