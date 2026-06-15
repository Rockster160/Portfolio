require "rails_helper"

RSpec.describe ChoreSerializer, "target_count + progress_count", type: :serializer do
  let(:user) { create(:user) }

  it "emits target_count and progress_count" do
    chore = create(:chore, created_by_user: user, target_count: 5)
    json = described_class.new(chore, viewer: user).as_json
    expect(json[:target_count]).to eq(5)
    expect(json[:progress_count]).to eq(0)
  end

  it "progress_count counts taps in the current chore-day" do
    chore = create(:chore, created_by_user: user, target_count: 3)
    today = ChoreDay.current(user)
    2.times { create(:chore_completion, chore: chore, user: user, day_key: today) }
    json = described_class.new(chore, viewer: user).as_json
    expect(json[:progress_count]).to eq(2)
    expect(json[:done_count_today]).to eq(2)
  end

  it "defaults to 1 when not set" do
    chore = create(:chore, created_by_user: user)
    json = described_class.new(chore, viewer: user).as_json
    expect(json[:target_count]).to eq(1)
  end

  it "yields the same value via bulk context as via lone serializer" do
    chore = create(:chore, created_by_user: user, target_count: 4)
    create(:chore_completion, chore: chore, user: user, day_key: ChoreDay.current(user))
    ctx = ChoreSerializerContext.for_user(user)
    via_ctx  = described_class.new(chore, viewer: user, ctx: ctx).as_json
    via_lone = described_class.new(chore, viewer: user).as_json
    expect(via_ctx[:target_count]).to eq(via_lone[:target_count])
    expect(via_ctx[:progress_count]).to eq(via_lone[:progress_count])
  end
end
