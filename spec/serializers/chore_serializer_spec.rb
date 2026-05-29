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

  it "today_visible is true for a freshly completed chore even when its enum would hide it" do
    chore = create(:chore, created_by_user: user, show_on_daily_view: :when_available,
                           threshold_seconds: 6.hours.to_i, recurrence: { freq: :never })
    ChoreCompleter.new(chore, user).call
    json = described_class.new(chore, viewer: user).as_json
    expect(json[:today_visible]).to be(true)
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
end
