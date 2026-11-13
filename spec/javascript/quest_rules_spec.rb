require "rails_helper"

# The quest board's rules run on the phone: what a count is, whether a quest is
# on the board, what a tap and a hold do. These drive the real module in node
# through the uses the board was built for.
RSpec.describe "the quest board rules (JS-side)" do
  let(:cases) { JsRunner.output("spec/javascript/quest_rules_runner.js", symbolize: true)[:cases] }

  it "takes the number in a quick add as the target and leaves {n} in the name" do
    expect(cases[:quick_add]).to eq(name: "Wish on {n} stars", target: 20)
    expect(cases[:quick_add_plain]).to eq(name: "Feed the cat", target: 1)
  end

  it "counts the hours before the reset hour toward the previous day" do
    expect(cases[:game_day_before_reset]).to eq("2026-11-04")
    expect(cases[:game_day_after_reset]).to eq("2026-11-05")
  end

  describe "wishing on stars, then collecting them" do
    it "has nothing to collect when nothing was wished on" do
      expect(cases[:stars_none]).not_to include("collect")
    end

    it "collects as many as were wished on the night before, after-midnight wishes included" do
      expect(cases[:stars_wished]).to eq(16)
      expect(cases[:stars_next_day]).to eq(
        visible:      ["wish", "collect", "shovel", "rock", "mush"],
        target:       16,
        name:         "Collect 16 stars",
        wishes_reset: 0,
      )
    end

    it "doesn't count past the target" do
      expect(cases[:stars_capped]).to eq(count: 16, again: nil)
      expect(cases[:wish_19_done]).to be(false)
      expect(cases[:wish_20_done]).to be(true)
    end
  end

  describe "a shovel topped up by rocks" do
    let(:shovel) { cases[:shovel] }

    it "keeps its points across days while the rock starts each day at zero" do
      expect(shovel[:next_day]).to eq(17)
      expect(shovel[:rock_today]).to eq(0)
    end

    it "takes the rock's points back off the shovel when the rock is held" do
      expect(shovel[:after_rock_undo]).to eq(17)
      expect(shovel[:undone_hooks]).to eq(1)
      expect(shovel[:second_rock_undo]).to be_nil
    end

    it "undoes the shovel's own tap, and a reset, from the shovel" do
      expect(shovel[:after_shovel_undo]).to eq(16)
      expect(shovel[:after_reset]).to eq(0)
      expect(shovel[:after_reset_undo]).to eq(16)
    end

    it "hands the hook the count it reached" do
      expect(shovel[:hook]).to include(kind: "event", name: "Rock", notes: "rock 1", state: "pending")
      expect(shovel[:hook][:data]).to include(count: 1, action: "tap")
    end
  end

  describe "mushrooms, daily in November" do
    it "is only on the board in November, by the game day" do
      expect(cases[:mush_october]).to be(false)
      expect(cases[:mush_november]).to be(true)
      expect(cases[:mush_dec1_2am]).to be(true)
    end

    it "fires its completion trigger only on the tap that finishes it" do
      expect(cases[:mush_hooks]).to eq(first: 0, last: [["mushrooms_done", "complete"]])
    end

    it "starts over the next day" do
      expect(cases[:mush_tomorrow]).to eq(0)
    end
  end

  it "runs an open-ended evening window past midnight to the reset hour" do
    expect(cases[:window_evening]).to be(true)
    expect(cases[:window_after_midnight]).to be(true)
    expect(cases[:window_noon]).to be(false)
  end

  it "shows a quest only on its days of the week" do
    expect(cases[:days_weds]).to be(true)
    expect(cases[:days_thu]).to be(false)
  end

  it "shows a conditional quest once the quest it waits on is done" do
    expect(cases[:gated_before]).to be(false)
    expect(cases[:gated_after]).to be(true)
  end

  it "starts a weekly quest's week on Monday" do
    expect(cases[:weekly_wed]).to eq("w:2026-11-02")
    expect(cases[:weekly_sun]).to eq("w:2026-11-02")
    expect(cases[:weekly_mon]).to eq("w:2026-11-09")
  end

  it "prunes old days and taps but keeps a count that never resets" do
    expect(cases[:prune]).to eq(periods: ["all"], log: 0)
  end

  it "shows a count-down quest as what's left, stopping at empty" do
    expect(cases[:down_new]).to eq(100)
    expect(cases[:down_after_rock]).to eq(92)
    expect(cases[:down_empty]).to eq(shown: 0, done: true)
  end

  it "sets a count straight to a number, the shown one for a count-down quest" do
    expect(cases[:set_count]).to eq(shown: 90, hooks: 0, undone: 100, capped: 20, same: nil)
  end

  describe "a batch quest: talk to every villager around, fifty days over" do
    let(:batch) { cases[:batch] }

    it "counts the talks done against the villagers around and can't be tapped" do
      expect(batch[:partway]).to eq(count: 2, target: 3, settle: 0)
      expect(batch[:tap_auto]).to be_nil
    end

    it "adds one to the fifty-day counter once, firing its hook as complete" do
      expect(batch[:doneDay]).to eq(done: true, fifty: 1)
      expect(batch[:fired]).to eq([[["talked_to_all", "complete"]]])
      expect(batch[:again]).to eq(0)
    end

    it "takes the day back when a talk under it is undone" do
      expect(batch[:reversed]).to eq(1)
      expect(batch[:after_undo]).to eq(0)
    end

    it "leaves out a villager who isn't around that day" do
      expect(batch[:thursday]).to eq(target: 2, done: true, fifty: 2)
      expect(batch[:nobody_visible]).to be(false)
    end

    it "takes any, and at least N" do
      expect(batch[:at_least]).to eq(count: 2, target: 2, done: true)
      expect(batch[:any]).to eq(target: 1, done: true)
    end
  end

  it "doesn't go round forever when batch quests read each other" do
    expect(cases[:batch_loop]).to eq(done: false, fired: 0)
  end

  describe "hidden quests" do
    let(:hidden) { cases[:hidden] }

    it "never shows a hidden quest on the board" do
      expect(hidden[:before]).to eq(["rock"])
      expect(hidden[:after]).to eq(["rock", "chest"])
      expect(hidden[:unhid]).to be(true)
    end

    it "still counts, finishes, fires and gates other quests while hidden" do
      expect(hidden[:gems]).to eq(3)
      expect(hidden[:key]).to be(true)
      expect(hidden[:fired]).to eq([["gems_found"]])
    end
  end

  it "keeps sections in the board's order, renaming and removing them with their quests" do
    expect(cases[:sections]).to eq(
      first: ["Visitors", "Dailies", "Old"],
      after: ["Dailies", "Villagers", "Long term"],
      items: ["Villagers", "Dailies", "", ""],
    )
  end
end
