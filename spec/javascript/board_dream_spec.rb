require "rails_helper"

# A board's pet dreams of one of its hot chores now and then. The script draws
# (buddy/dream.js) and the server draws the same thing to open the page on the
# right face (Buddy::BoardDream), so the two must agree exactly or the pet
# flips the moment the script runs.
RSpec.describe "Board dreams" do
  def chore(id, weight, **over)
    {
      id:             id,
      kind:           "chore",
      hot_weight:     weight,
      today_visible:  true,
      archived:       false,
      progress_count: 0,
      target_count:   1,
      skipped_today:  false,
      dismissed:      false,
    }.merge(over)
  end

  let(:items) {
    [
      chore(7, 2.0),
      chore(3, 1.5),
      chore(12, 3.0),
      chore(5, 1.0, progress_count: 1),
      chore(9, 1.0, dismissed: true),
      chore(4, nil),
      { id: 2, kind: "trigger", hot_weight: 5.0 },
    ]
  }
  let(:boards) { [1, 42, 977] }
  # Two days of half hours, so every candidate (and nothing) comes up.
  let(:times) { (0...96).map { |i| Time.utc(2026, 10, 16) + (i * 30.minutes) + 7.minutes } }

  let(:js) {
    JsRunner.eval_module(<<~JS)
      const { pickChoreDream, mulberry32 } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/dream.js").to_s.to_json});
      const items = #{items.to_json};
      const boards = #{boards.to_json};
      const times = #{times.map { |t| (t.to_f * 1000).to_i }.to_json};
      const picks = boards.map((b) => times.map((t) => pickChoreDream(items, b, t)?.id ?? null));
      const randoms = [0, 1, 31, 123456789, 4294967295].map((s) => mulberry32(s));
      process.stdout.write(JSON.stringify({ picks, randoms }));
    JS
  }

  it "draws the same random numbers on both sides" do
    ruby = [0, 1, 31, 123_456_789, 4_294_967_295].map { |s| Buddy::BoardDream.random(s) }

    expect(js["randoms"]).to eq(ruby)
  end

  it "picks the same chore (or nothing) for every board and half hour" do
    ruby = boards.map { |b| times.map { |t| Buddy::BoardDream.pick(items, b, at: t)&.dig(:id) } }

    expect(js["picks"]).to eq(ruby)
  end

  it "only ever dreams of a hot chore still asking, and sometimes of nothing" do
    seen = js["picks"].flatten.uniq

    expect(seen - [7, 3, 12, nil]).to be_empty
    expect(seen).to include(nil, 7, 12)
  end

  # A board's own pace: dreams of a set length with set breaks between them.
  # Both sides have to agree on where the breaks fall as well as on the draw.
  describe "with a pace" do
    let(:paces) { [[15, 0], [60, 120], [30, 240], [120, 30]] }
    let(:paced) {
      JsRunner.eval_module(<<~JS)
        const { pickChoreDream } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/dream.js").to_s.to_json});
        const items = #{items.to_json};
        const times = #{times.map { |t| (t.to_f * 1000).to_i }.to_json};
        const paces = #{paces.to_json};
        const picks = paces.map(([d, b]) => times.map((t) => pickChoreDream(items, 42, t, { dreamMinutes: d, breakMinutes: b })?.id ?? null));
        process.stdout.write(JSON.stringify(picks));
      JS
    }

    it "picks the same chore (or nothing) on both sides" do
      ruby = paces.map { |d, b|
        times.map { |t| Buddy::BoardDream.pick(items, 42, at: t, dream_minutes: d, break_minutes: b)&.dig(:id) }
      }

      expect(paced).to eq(ruby)
    end

    it "dreams of nothing through a break" do
      start = Time.utc(2026, 10, 16, 0)
      # An hour's dream then two hours off: 1:00-3:00 is the break.
      during = [70, 120, 179].map { |m|
        Buddy::BoardDream.pick(items, 42, at: start + m.minutes, dream_minutes: 60, break_minutes: 120)
      }

      expect(during.compact).to be_empty
    end
  end

  it "holds one pick for the whole half hour" do
    start = Time.utc(2026, 10, 16, 9)
    picks = [0, 10, 29].map { |m| Buddy::BoardDream.pick(items, 42, at: start + m.minutes)&.dig(:id) }

    expect(picks.uniq.size).to eq(1)
  end
end
