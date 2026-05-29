require "rails_helper"

RSpec.describe ChoreSerializer, type: :serializer do
  let(:user)  { create(:user) }
  let(:chore) {
    create(:chore, created_by_user: user, name: "Brush Teeth",
                   short_name: "Brush", icon: "🪥", reward_pebbles: 1,
                   threshold_seconds: 3600)
  }

  it "emits the canonical contract that ChoreStore reads" do
    json = described_class.new(chore, viewer: user).as_json
    expect(json).to include(
      id: chore.id,
      name: "Brush Teeth",
      short_name: "Brush",
      icon: "🪥",
      reward_pebbles: 1,
      threshold_seconds: 3600,
      cooldown_kind: :fixed,
      icon_kind: :emoji,
      done_count_today: 0,
      hot_multiplier: nil,
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
      grid_only = create(:chore, created_by_user: user, show_on_daily_view: :when_scheduled,
                                 recurrence: { freq: :never })
      expect(render(grid_only)[:today_visible]).to be(false)
      ChoreCompleter.new(grid_only, user).call
      expect(render(grid_only)[:today_visible]).to be(false)
    end

    it ":when_scheduled — scheduled today stays on after completion" do
      scheduled = create(:chore, created_by_user: user, show_on_daily_view: :when_scheduled,
                                 recurrence: { freq: :daily })
      expect(render(scheduled)[:today_visible]).to be(true)
      ChoreCompleter.new(scheduled, user).call
      expect(render(scheduled)[:today_visible]).to be(true)
    end

    it ":when_available — cooldown active at day-start stays off after completion" do
      # Completed yesterday well within an 8h cooldown — at 4am today
      # the cooldown is still active, so the chore is NOT on Today.
      # Tapping it from Grid (skipped payout, but still a completion)
      # must not move it onto Today.
      ch = create(:chore, created_by_user: user, show_on_daily_view: :when_available,
                          threshold_seconds: 8.hours.to_i, recurrence: { freq: :never })
      create(:chore_completion, chore: ch, user: user, paid_pebbles: 1,
             completed_at: 2.hours.ago, day_key: today - 1)
      expect(render(ch)[:today_visible]).to be(false)
      ChoreCompleter.new(ch, user).call
      expect(render(ch)[:today_visible]).to be(false)
    end

    it ":when_available — cooldown elapsed at day-start stays on after completion" do
      # Yesterday's completion is long past its 4h cooldown. Chore is
      # on Today at 4am. Completing it (which re-engages cooldown)
      # must not flip it off — the membership decision is locked.
      ch = create(:chore, created_by_user: user, show_on_daily_view: :when_available,
                          threshold_seconds: 4.hours.to_i, recurrence: { freq: :never })
      create(:chore_completion, chore: ch, user: user, paid_pebbles: 1,
             completed_at: 24.hours.ago, day_key: today - 1)
      expect(render(ch)[:today_visible]).to be(true)
      ChoreCompleter.new(ch, user).call
      expect(render(ch)[:today_visible]).to be(true)
    end

    it "payment status doesn't affect visibility — a skipped completion " \
       "before today behaves the same as a paid one" do
      # Two identical chores, one with a PAID completion yesterday,
      # one with a SKIPPED completion yesterday. today_visible? must
      # agree — payment is a payout concern, not a visibility one.
      paid_ch    = create(:chore, created_by_user: user, show_on_daily_view: :when_scheduled,
                                  recurrence: { freq: :daily })
      skipped_ch = create(:chore, created_by_user: user, show_on_daily_view: :when_scheduled,
                                  recurrence: { freq: :daily })
      create(:chore_completion, chore: paid_ch,    user: user, paid_pebbles: 1,
             completed_at: 6.hours.ago, day_key: today - 1, payout_skipped: false)
      create(:chore_completion, chore: skipped_ch, user: user, paid_pebbles: 0,
             completed_at: 6.hours.ago, day_key: today - 1, payout_skipped: true)
      expect(render(paid_ch)[:today_visible]).to eq(render(skipped_ch)[:today_visible])
    end

    it ":when_scheduled — carryover survives a completion made today" do
      # Scheduled every 3 days, last appeared 2 days ago, never
      # completed. It's "carried over" to today. A completion made
      # today closes out the carryover, but today_visible must not
      # flip — Today is locked once we're inside it.
      starts_on = today - 2
      ch = create(:chore, created_by_user: user, show_on_daily_view: :when_scheduled,
                          recurrence: { freq: :custom, every: 3, unit: :day }, starts_on: starts_on)
      expect(render(ch)[:today_visible]).to be(true)
      ChoreCompleter.new(ch, user).call
      expect(render(ch)[:today_visible]).to be(true)
    end
  end
end
