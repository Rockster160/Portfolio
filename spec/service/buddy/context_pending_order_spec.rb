require "rails_helper"

# What order the briefing reads the pending list in.
#
# Aug 7: both briefings that went out named the dailies first — "Cymbalta,
# water, teeth…" and "teeth, kitty litter, puppy feeding, water, and Wordle…" —
# because the bucket was built `daily_ids + hot_ids + marked_today` and they
# read straight down it. The seed says the opposite: a daily is something known
# cold, and the thing stamped due today is the one nobody remembers.
RSpec.describe "Buddy pending chore order" do
  let(:user) { create(:user) }
  let(:today) { Date.current }

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

  def pending_names
    Buddy::Context.send(:build_chore_buckets, user, today)[:pending_today].pluck(:name)
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
end
