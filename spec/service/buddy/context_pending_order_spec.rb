require "rails_helper"

# What order the briefing reads the pending list in.
#
# Aug 7: both briefings that went out named the dailies first — "Cymbalta,
# water, teeth…" and "teeth, kitty litter, puppy feeding, water, and Wordle…" —
# because the bucket was built `daily_ids + hot_ids + marked_today` and they
# read straight down it. The seed says the opposite: a daily is something known
# cold, and the thing stamped due today is the one nobody remembers.
RSpec.describe "Buddy pending chore order" do
  # Pinned to the middle of a day on purpose. A chore day runs 4am to 4am
  # (ChoreDay::CUTOFF_HOURS), so between midnight and 4 the calendar date has
  # rolled and the chore day hasn't — `Date.current` names tomorrow, every
  # `marked_due_at: Time.current` lands before the window, and the whole file
  # fails for reasons that have nothing to do with ordering. It did exactly
  # that, on an unchanged tree, at 8:41pm Mountain.
  around { |ex| travel_to(Time.zone.parse("2026-08-08 15:00 UTC")) { ex.run } }

  let(:user) { create(:user) }
  let(:today) { ChoreDay.current(user) }

  def daily(name)
    chore = create(:chore, name: name, created_by_user: user)
    user.chore_dailies.create!(chore: chore)
    chore
  end

  def due_today(name)
    create(:chore, name: name, created_by_user: user, marked_due_at: Time.current)
  end

  def hot(chore, multiplier)
    ChoreHotPick.create!(chore: chore, day_key: today, multiplier: multiplier)
    chore
  end

  def buckets
    Buddy::Context.send(:build_chore_buckets, user, today)
  end

  def pending_names
    buckets[:pending_today].pluck(:name)
  end

  def due_today_names
    buckets[:due_today].pluck(:name)
  end

  it "puts a one-off stamped for today ahead of the daily habits" do
    daily("Teeth")
    daily("Water")
    due_today("Gutters")

    expect(pending_names.first).to eq("Gutters")
  end

  it "keeps the dailies rather than dropping them" do
    daily("Teeth")
    due_today("Gutters")

    expect(pending_names).to contain_exactly("Gutters", "Teeth")
    expect(pending_names.last).to eq("Teeth")
  end

  it "sorts the hot picks by how hot they are, under the due-today one" do
    due_today("Gutters")
    hot(daily("Litter"), 2)
    hot(daily("Wipe"), 5)

    expect(pending_names).to eq(%w[Gutters Wipe Litter])
  end

  # It's still the habit they know cold; the stamp only says it's on today,
  # which every daily already is.
  it "leaves a daily that is ALSO stamped for today with the dailies" do
    chore = daily("Teeth")
    chore.update!(marked_due_at: Time.current)
    due_today("Gutters")

    expect(pending_names.first).to eq("Gutters")
  end

  # Sorting wasn't enough. Aug 7 AND Aug 8 both read the dailies out in full
  # under a prompt saying at most three names, because all of them were sitting
  # right there. `chores_due_today` is the short list the briefing names from —
  # the same records, with the habits taken out.
  describe "the briefing's own list" do
    it "holds what's due today and nothing habitual" do
      daily("Teeth")
      daily("Water")
      due_today("Gutters")

      expect(due_today_names).to eq(["Gutters"])
    end

    it "counts a hot pick, since pinning it for today is what due today means" do
      hot(create(:chore, name: "Litter", created_by_user: user), 5)

      expect(due_today_names).to eq(["Litter"])
    end

    it "drops a daily even when it's been pinned hot" do
      hot(daily("Wipe"), 5)

      expect(due_today_names).to be_empty
    end

    it "comes back empty on a day that's only habits, rather than reaching for one" do
      daily("Teeth")
      daily("Water")

      expect(due_today_names).to be_empty
      # The habits are still in context — they just aren't what gets named.
      expect(pending_names).to contain_exactly("Teeth", "Water")
    end

    it "leaves one out once it's done" do
      chore = due_today("Gutters")
      create(:chore_completion, chore: chore, user: user)

      expect(due_today_names).to be_empty
    end
  end
end

# A chore day rolls at 4am (ChoreDay), the perceived day at 3am
# (User#perceived_today). Between them sits an hour where the two names
# disagree, and the buckets are keyed the ChoreDay way throughout — completions,
# hot picks, and the marked-due window all land a day off if the perceived date
# is what gets passed in. Its own file-level block because it needs its own
# clock, and travel_to doesn't nest.
RSpec.describe "Buddy chores across the 3am-to-4am seam" do
  around { |ex| travel_to(Time.find_zone("America/Denver").parse("2026-08-08 03:30")) { ex.run } }

  # User#timezone is hardcoded to America/Denver, which is what both rollovers
  # are read in — so 3:30am Denver is genuinely inside the seam.
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

  before { user.update!(chore_household_id: household.id) }

  def daily(name)
    chore = create(:chore, name: name, created_by_user: user)
    user.chore_dailies.create!(chore: chore)
    chore
  end

  def due_today(name)
    create(:chore, name: name, created_by_user: user, marked_due_at: Time.current)
  end

  describe "which day the buckets are built for" do
    it "disagrees with the perceived date, which is the whole problem" do
      expect(user.perceived_today).to eq(Date.new(2026, 8, 8))
      expect(ChoreDay.current(user)).to eq(Date.new(2026, 8, 7))
    end

    it "still counts a chore stamped due in that hour as due, not overdue" do
      due_today("Gutters")

      buckets = Buddy::Context.send(:build_chore_buckets, user, ChoreDay.current(user))

      expect(buckets[:due_today].pluck(:name)).to eq(["Gutters"])
      expect(buckets[:overdue_backlog].pluck(:name)).to be_empty
    end

    it "sees a completion logged in that hour as done" do
      chore = daily("Teeth")
      create(:chore_completion, chore: chore, user: user)

      buckets = Buddy::Context.send(:build_chore_buckets, user, ChoreDay.current(user))

      expect(buckets[:pending_today].pluck(:name)).to be_empty
      expect(buckets[:done_today].pluck(:name)).to eq(["Teeth"])
    end

    # What the context actually hands the model, rather than what a helper
    # called directly does — the bug was entirely in which date got passed.
    it "builds the real context off the chore day" do
      due_today("Gutters")
      conversation = user.byte_conversations.create!(mode: :buddy, name: "Buddy")

      context = Buddy::Context.full(user, conversation)

      expect(context[:chores_due_today].pluck(:name)).to eq(["Gutters"])
      expect(context[:chores_overdue_backlog]).to be_empty
    end
  end
end
