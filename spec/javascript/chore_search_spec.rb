require "rails_helper"

# The one chore search every picker uses: the Chores page's box, and a board's
# pin and credit-button pickers.
RSpec.describe "Chore search" do
  let(:chores) {
    [
      { id: 1, name: "Feed Spiders", short_name: "Spiders", aliases: ["tarantulas"] },
      { id: 2, name: "Spray spiders", short_name: "Spray", aliases: [] },
      { id: 3, name: "Litter box", short_name: "Litter", aliases: ["cat poop"] },
    ]
  }

  let(:found) {
    JsRunner.eval_module(<<~JS)
      const { searchChores } = await import(#{Rails.root.join("app/javascript/src/chore_search.js").to_s.to_json});
      const chores = #{chores.to_json};
      const ids = (q) => searchChores(chores, q).map((c) => c.id);
      process.stdout.write(JSON.stringify({ tarantula: ids("tarantula"), poop: ids("poop"), spi: ids("spi"), all: ids("") }));
    JS
  }

  it "finds a chore by an alias as well as its name" do
    expect(found["tarantula"]).to eq([1])
    expect(found["poop"]).to eq([3])
  end

  # The short name is what a chore is called on every surface, so it's what
  # the search reads, with the aliases.
  it "searches the short name, not the full one" do
    expect(found["spi"]).to eq([1])
  end

  it "offers everything for an empty search" do
    expect(found["all"]).to contain_exactly(1, 2, 3)
  end

  # The same field syntax the History filter takes, read against the chore.
  describe "fields" do
    let(:today) { "2026-10-29" }
    let(:fielded) {
      [
        {
          id:                  1,
          name:                "Feed Spiders",
          short_name:          "Spiders",
          aliases:             ["tarantulas"],
          tags:                ["Pets", "Front yard"],
          marked_due_on:       "2026-10-29",
          reward_pebbles:      2,
          done_count_today:    1,
          assigned_to_user_id: 7,
        },
        {
          id:               2,
          name:             "Spray spiders",
          short_name:       "Spray",
          aliases:          [],
          tags:             ["Yard"],
          scheduled_due_on: "2026-11-02",
          reward_pebbles:   5,
          done_count_today: 0,
        },
        { id: 3, name: "Litter box", short_name: "Litter", aliases: ["cat poop"], tags: [], reward_pebbles: 1 },
        { id: 4, name: "Water plants", short_name: "Water", aliases: [], tags: [], marked_due_on: "2026-10-20" },
      ]
    }
    let(:hits) {
      queries = [
        "group:yard",
        "group::yard",
        "tag:none",
        "group:\"front yard\"",
        "nick:spi",
        "name:spiders",
        "due:today",
        "due<+7",
        "due>today",
        "due:none",
        "due:overdue",
        "is:done",
        "-is:done",
        "reward>=2",
        "for:sam",
        "spi OR litter",
        "-spiders",
        "group:pets spiders",
        "box:3",
      ]
      JsRunner.eval_module(<<~JS)
        const { searchChores } = await import(#{Rails.root.join("app/javascript/src/chore_search.js").to_s.to_json});
        const chores = #{fielded.to_json};
        const ctx = { today: #{today.to_json}, users: { 7: "sam" } };
        const out = {};
        for (const q of #{queries.to_json}) out[q] = searchChores(chores, q, ctx).map((c) => c.id).sort();
        process.stdout.write(JSON.stringify(out));
      JS
    }

    it "reads groups, by part, exactly, quoted, or none at all" do
      expect(hits["group:yard"]).to eq([1, 2])
      expect(hits["group::yard"]).to eq([2])
      expect(hits["group:\"front yard\""]).to eq([1])
      expect(hits["tag:none"]).to eq([3, 4])
    end

    it "reaches the nickname and the full name separately" do
      expect(hits["nick:spi"]).to eq([1])
      expect(hits["name:spiders"]).to eq([1, 2])
    end

    it "compares due dates against the chore day" do
      expect(hits["due:today"]).to eq([1])
      expect(hits["due<+7"]).to eq([1, 2, 4])
      expect(hits["due>today"]).to eq([2])
      expect(hits["due:none"]).to eq([3])
      expect(hits["due:overdue"]).to eq([4])
    end

    it "takes flags, numbers, assignees and negation" do
      expect(hits["is:done"]).to eq([1])
      expect(hits["-is:done"]).to eq([2, 3, 4])
      expect(hits["reward>=2"]).to eq([1, 2])
      expect(hits["for:sam"]).to eq([1])
      expect(hits["-spiders"]).to eq([2, 3, 4])
    end

    it "joins runs with OR and mixes fields with words" do
      expect(hits["spi OR litter"]).to eq([1, 3])
      expect(hits["group:pets spiders"]).to eq([1])
    end

    it "keeps a colon that names no field as part of a word" do
      expect(hits["box:3"]).to eq([])
    end
  end
end
