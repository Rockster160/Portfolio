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

  # A board's own pace: how often it draws, how often a draw is blank, a rest
  # after each dream and quiet hours. Both sides have to agree on all of it.
  describe "with a pace" do
    let(:paces) {
      [
        { every: 15, blank: 0, rest: 0 },
        { every: 60, blank: 50, rest: 120 },
        { every: 30, blank: 25, rest: 60, quiet_from: 21, quiet_to: 7 },
        { every: 120, blank: 75, rest: 240, quiet_from: 9, quiet_to: 17 },
      ]
    }
    let(:offset) { -360 }
    let(:paced) {
      JsRunner.eval_module(<<~JS)
        const { pickChoreDream } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/dream.js").to_s.to_json});
        const items = #{items.to_json};
        const times = #{times.map { |t| (t.to_f * 1000).to_i }.to_json};
        const paces = #{paces.map { |p| { every: p[:every], blank: p[:blank], rest: p[:rest], quietFrom: p[:quiet_from], quietTo: p[:quiet_to] } }.to_json};
        const picks = paces.map((p) => times.map((t) => pickChoreDream(items, 42, t, p, #{offset})?.id ?? null));
        process.stdout.write(JSON.stringify(picks));
      JS
    }

    def ruby_picks(pace)
      times.map { |t| Buddy::BoardDream.pick(items, 42, at: t, pace: pace, utc_offset: offset)&.dig(:id) }
    end

    it "picks the same chore (or nothing) on both sides" do
      expect(paced).to eq(paces.map { |pace| ruby_picks(pace) })
    end

    it "never draws a blank when the chance is none" do
      expect(ruby_picks(every: 30, blank: 0, rest: 0)).not_to include(nil)
    end

    it "rests after a dream" do
      picks = ruby_picks(every: 30, blank: 0, rest: 60)

      # Each dream is followed by two half hours of nothing, then the next.
      shown = picks.each_index.select { |i| picks[i] }
      expect(shown.each_cons(2).map { |a, b| b - a }.uniq).to eq([3])
    end

    it "dreams of nothing in quiet hours, in the board's own time" do
      # 9 PM-7 AM at UTC-6 is 03:00-13:00 UTC.
      picks = times.zip(ruby_picks(every: 30, blank: 0, rest: 0, quiet_from: 21, quiet_to: 7))
      quiet, awake = picks.partition { |t, _| (3...13).cover?(t.utc.hour) }

      expect(quiet.map(&:last).compact).to be_empty
      expect(awake.map(&:last)).not_to include(nil)
    end
  end

  # Tapping the pet puts its dream away until the next draw.
  describe "once the pet is tapped" do
    let(:tapped) { Time.utc(2026, 10, 16, 9, 10) }
    let(:dismissed) {
      JsRunner.eval_module(<<~JS)
        const { pickChoreDream } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/dream.js").to_s.to_json});
        const items = #{items.to_json};
        const pace = { every: 30, blank: 0, rest: 0 };
        const picks = #{[12, 29, 31].map { |m| ((tapped.beginning_of_hour + m.minutes).to_f * 1000).to_i }.to_json}
          .map((t) => pickChoreDream(items, 42, t, pace, 0, #{(tapped.to_f * 1000).to_i})?.id ?? null);
        process.stdout.write(JSON.stringify(picks));
      JS
    }

    it "dreams of nothing for the rest of that draw, then picks up again, on both sides" do
      ruby = [12, 29, 31].map { |m|
        Buddy::BoardDream.pick(
          items, 42, at: tapped.beginning_of_hour + m.minutes, pace: { every: 30, blank: 0, rest: 0 }, dismissed_at: tapped,
        )&.dig(:id)
      }

      expect(ruby.first(2)).to eq([nil, nil])
      expect(ruby.last).to be_present
      expect(dismissed).to eq(ruby)
    end
  end

  it "holds one pick for the whole half hour" do
    start = Time.utc(2026, 10, 16, 9)
    picks = [0, 10, 29].map { |m| Buddy::BoardDream.pick(items, 42, at: start + m.minutes)&.dig(:id) }

    expect(picks.uniq.size).to eq(1)
  end
end
