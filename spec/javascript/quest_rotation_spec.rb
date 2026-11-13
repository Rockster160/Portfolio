require "rails_helper"

# A rotation quest runs on the phone: one daily pick, each option at most once
# a week, extras on top. These drive the real module in node.
RSpec.describe "the quest board rotation (JS-side)" do
  let(:cases) { JsRunner.output("spec/javascript/quest_rotation_runner.js", symbolize: true)[:cases] }

  it "runs the week Monday to Sunday" do
    expect(cases[:week].values_at(0, 6)).to eq(["2026-11-09", "2026-11-15"])
  end

  it "fills a fixed day without anything recorded" do
    expect(cases[:mains]).to eq(["b", "a", nil, nil, nil, "sat", "sun"])
  end

  it "marks due only a daily option missing from both this week and last" do
    expect(cases[:standings]).to include(
      a:   { picked: true, due: false },
      b:   { picked: true, due: false },
      c:   { picked: false, due: false },
      d:   { picked: false, due: true },
      sat: { picked: true, due: false },
      x:   { picked: false, due: false },
    )
  end

  it "lets a recorded pick take a fixed day's place" do
    expect(cases[:fixed_displaced][:main]).to eq("d")
    expect(cases[:fixed_displaced][:standings][:sat]).to eq(picked: false, due: false)
  end

  it "keeps an extra beside the day's pick and takes it back on a second tap" do
    expect(cases[:extra]).to eq(main: "sun", extras: ["x"])
    expect(cases[:extra_taken_back]).to eq([])
  end

  it "clears a pick tapped again" do
    expect(cases[:main_taken_back]).to be_nil
  end

  it "forgets old days and a deleted rotation's picks" do
    expect(cases[:pruned][:days]).not_to include("2026-08-01")
    expect(cases[:pruned][:rotations]).to eq(["visitors"])
  end

  describe "quests that only show while a visitor is in town" do
    let(:visitor) { cases[:visitor] }

    it "shows the visitor's quests only on the days it's here" do
      expect(visitor[:before]).to eq(["quiet"])
      expect(visitor[:wisp_day]).to eq(["spirits"])
      expect(visitor[:next_day]).to eq(["quiet", "after"])
    end

    it "counts a fixed day and an extra as being here" do
      expect(visitor[:saturday]).to eq(["quiet", "on_sat", "with_x"])
    end

    it "takes the quest back off when the pick is taken back" do
      expect(visitor[:wisp_taken_back]).to eq(["quiet"])
    end

    it "drops a condition whose visitor was removed, so the quest isn't stuck hidden" do
      expect(visitor[:removed][:spirits]).to eq([])
      expect(visitor[:removed][:on_sat]).to eq(1)
    end
  end
end
