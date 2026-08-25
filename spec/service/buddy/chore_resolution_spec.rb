require "rails_helper"

# Which chore a fuzzy name lands on. This matters more than most resolvers
# because complete_chore runs the instant it resolves — a wrong match doesn't
# ask, it writes a completion for something nobody did.
RSpec.describe "Buddy chore resolution" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let(:ctx)        { Buddy::ToolContext.new(user) }

  def chore!(name)
    create(:chore, created_by_user: user, chore_household: household, name: name)
  end

  it "takes an exact name over anything else" do
    chore!("Water plants")
    exact = chore!("Water")

    expect(ctx.resolve_chore("water")).to eq(exact)
  end

  # Prod 1357-1363: "water" matched both "Wash Water Bowls" (id 5) and "8oz
  # Water" (id 9), enumeration order picked the lower id, and someone logging
  # that they drank something got three bowl-washings marked off.
  describe "when several names contain what they said" do
    it "picks the one the word is mostly ABOUT, not the one that mentions it" do
      chore!("Wash Water Bowls")
      drink = chore!("8oz Water")

      expect(ctx.resolve_chore("water")).to eq(drink)
    end

    it "doesn't depend on which was created first" do
      drink = chore!("8oz Water")
      chore!("Wash Water Bowls")

      expect(ctx.resolve_chore("water")).to eq(drink)
    end

    it "still finds the long name when that's what they typed" do
      bowls = chore!("Wash Water Bowls")
      chore!("8oz Water")

      expect(ctx.resolve_chore("wash water bowls")).to eq(bowls)
    end
  end

  # Prod 4495, 09:25. Chelsea said "Log load dishwasher" and Moss answered "I
  # marked the dishwasher one off.. it landed on **Unload Dishwasher**" -
  # `chore_completions` 2626, chore 78. Loading and unloading are opposite jobs
  # and it wrote the opposite one, because "unload dishwasher" contains "load
  # dishwasher".
  describe "a name glued to the front of a longer word" do
    it "does not read as the shorter word" do
      chore!("Unload Dishwasher")
      chore!("Light Load Dishes")
      chore!("Medium~Normal Load Dishes")

      expect(ctx.resolve_chore("load dishwasher")).to be_nil
    end

    # The Levenshtein fallback is the other route to the same row - two edits
    # against a tolerance of five - so refusing it in one place only moves it.
    it "does not come back by edit distance either" do
      chore!("Unload Dishwasher")

      expect(ctx.resolve_chore("load dishwasher")).to be_nil
    end

    it "names the ones she might have meant instead of guessing" do
      chore!("Unload Dishwasher")
      chore!("Light Load Dishes")
      chore!("Medium~Normal Load Dishes")

      expect(ctx.no_chore_error("load dishwasher")).to include("Light Load Dishes", "Medium~Normal Load Dishes")
    end

    it "still finds the row when they say the whole thing" do
      unload = chore!("Unload Dishwasher")

      expect(ctx.resolve_chore("unload dishwasher")).to eq(unload)
    end

    # Only the LEADING edge. What follows is ordinary inflection and has never
    # changed what a chore is.
    it "leaves a plural or a participle alone" do
      dishes  = chore!("Dishes")
      beds    = chore!("Watering the Beds")

      expect(ctx.resolve_chore("dish")).to eq(dishes)
      expect(ctx.resolve_chore("water")).to eq(beds)
    end
  end

  describe "when nothing contains it" do
    it "forgives a typo" do
      brush = chore!("Brush Teeth")

      expect(ctx.resolve_chore("brush teth")).to eq(brush)
    end

    # "waters" used to come back "Shower" — five edits away, and simply the
    # least-bad of a field that had nothing in it. Resolving to nothing raises,
    # which makes Buddy ask instead of act.
    it "gives up rather than handing back the closest of a bad field" do
      chore!("Shower")
      chore!("Feed Byte")

      expect(ctx.resolve_chore("waters")).to be_nil
    end

    it "gives up on a word with no relation to anything" do
      chore!("Brush Teeth")

      expect(ctx.resolve_chore("helicopter")).to be_nil
    end
  end

  it "returns nothing for a blank name" do
    chore!("Brush Teeth")

    expect(ctx.resolve_chore("")).to be_nil
    expect(ctx.resolve_chore(nil)).to be_nil
  end

  # "Another water" is water, again. The extra word says HOW MANY, and matching
  # only ever asked whether a chore NAME contains what was said - so bare
  # "water" resolved and every phrase built around it missed.
  #
  # Prod 3800-3808. "Water cup yesterday" landed two waters because the model
  # passed the exact name; forty seconds later "Add it as one more" and "No,
  # mark another water done yesterday" both came back "that didn't match a
  # water chore name", and the attempt in between gave up on chores entirely
  # and wrote an ActionEvent, reported as though the chore had been ticked.
  describe "a repeat of something already named" do
    before do
      chore!("8oz Water")
      chore!("Wash Water Bowls")
    end

    [
      "another water",
      "one more water",
      "water again",
      "1 more water",
      "an extra water",
      "more water",
      "waters",
    ].each do |phrasing|
      it "reads #{phrasing.inspect} as the water chore" do
        expect(ctx.resolve_chore(phrasing)&.name).to eq("8oz Water")
      end
    end

    # The repeat word is only stripped once the name AS GIVEN has failed, so a
    # chore actually called one of these keeps its own name.
    it "prefers a chore whose real name contains the word" do
      extra = chore!("Extra Laundry")

      expect(ctx.resolve_chore("extra laundry")).to eq(extra)
    end

    it "still gives up when the remainder means nothing" do
      expect(ctx.resolve_chore("another helicopter")).to be_nil
    end

    it "doesn't resolve a bare repeat word to anything" do
      expect(ctx.resolve_chore("another")).to be_nil
      expect(ctx.resolve_chore("again")).to be_nil
    end
  end

  # Containment runs one way only: it asks whether a chore NAME contains what
  # was said, never the reverse. So bare "water" resolves and every phrase
  # BUILT on it misses, which is the shape a person's own words arrive in.
  #
  # Prod 3800-3808, inside 75 seconds. "Water cup yesterday" worked because the
  # model happened to pass the exact name; then "Add it as one more" and "No,
  # mark another water done yesterday" both failed, and the attempt between them
  # gave up on chores altogether and wrote an ActionEvent (msg 3805), reported
  # as though the chore had been ticked. 8/14 is still one water short.
  #
  # Loosening the match is the wrong fix and the comment on FUZZY_TOLERANCE is
  # why - a completion written against the wrong chore is a false record that
  # looks exactly like a true one. What was missing is a failure the model can
  # act on.
  describe "the failure a miss reports" do
    before do
      chore!("8oz Water")
      chore!("Wash Water Bowls")
      chore!("Water plants")
    end

    # "water cup" is the person's own name for it and there's no repeat word to
    # take off, so it still misses — and should, with three chores containing
    # "water" and nothing to choose between them. This is what the suggestions
    # are for.
    it "still refuses to guess" do
      expect(ctx.resolve_chore("water cup")).to be_nil
      expect(ctx.resolve_chore("the cup thing")).to be_nil
    end

    it "names what they might have meant" do
      expect(ctx.chore_suggestions("one more water")).to include("8oz Water")
    end

    it "ranks the shortest name first when they all share one word" do
      expect(ctx.chore_suggestions("water cup").first).to eq("8oz Water")
    end

    it "ranks a name sharing TWO words above one sharing a single word" do
      expect(ctx.chore_suggestions("wash the bowls").first).to eq("Wash Water Bowls")
    end

    it "suggests nothing when the words have no chore in them" do
      expect(ctx.chore_suggestions("helicopter")).to eq([])
    end

    # Otherwise "add it as one more" suggests every chore whose name happens to
    # contain "it" or "a".
    it "suggests nothing from filler alone" do
      expect(ctx.chore_suggestions("add it as one more")).to eq([])
    end

    it "handles a blank without raising" do
      expect(ctx.chore_suggestions(nil)).to eq([])
    end

    describe "the message the tools raise" do
      it "carries the near misses and says to call again" do
        message = ctx.no_chore_error("one more water")

        expect(message).to include("no chore matching")
        expect(message).to include("8oz Water")
        expect(message).to include("Call again")
      end

      # The third attempt in prod reached for log_event and told the person the
      # chore was done. Whatever else a miss leads to, it can't be that.
      it "rules out swapping in another tool" do
        expect(ctx.no_chore_error("one more water")).to include("Never substitute another tool")
      end

      it "stays a plain miss when there's nothing to suggest" do
        message = ctx.no_chore_error("helicopter")

        expect(message).to eq('no chore matching "helicopter"')
      end

      it "keeps a caller's own wording" do
        expect(ctx.no_chore_error("helicopter", suffix: "to follow"))
          .to eq('no chore matching "helicopter" to follow')
      end
    end
  end
end
