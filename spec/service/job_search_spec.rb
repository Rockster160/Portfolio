require "rails_helper"

RSpec.describe JobSearch do
  let(:user) { create(:user) }

  def job(company, **attrs)
    user.job_applications.create!(company: company, **attrs)
  end

  def search(query, scope: user.job_applications)
    described_class.call(scope, query).map(&:company)
  end

  describe "ranking" do
    # The whole point. A note mentioning a company must not outrank the company
    # itself, however recently it was touched.
    it "puts the company above a more recent application that only mentions it" do
      netflix = job("Netflix")
      netflix.notes.create!(tag: :applied, occurred_at: 30.days.ago)
      netflix.touch_activity!

      gossip = job("Anrok")
      gossip.notes.create!(tag: :note, body: "Recruiter used to work at Netflix.", occurred_at: 1.hour.ago)
      gossip.touch_activity!

      expect(search("netflix")).to eq(["Netflix", "Anrok"])
    end

    it "reads exact, then prefix, then anywhere in the name" do
      job("Anrok Analytics")     # contains
      job("Rok")                 # exact
      job("Rokfin")              # prefix

      expect(search("rok")).to eq(["Rok", "Rokfin", "Anrok Analytics"])
    end

    it "breaks a tie on the most recent activity" do
      old = job("Acme One")
      old.notes.create!(tag: :applied, occurred_at: 20.days.ago)
      old.touch_activity!

      fresh = job("Acme Two")
      fresh.notes.create!(tag: :applied, occurred_at: 1.day.ago)
      fresh.touch_activity!

      expect(search("acme")).to eq(["Acme Two", "Acme One"])
    end
  end

  describe "what it looks through" do
    it "finds a role" do
      job("Netflix", role: "Staff Engineer")

      expect(search("staff")).to eq(["Netflix"])
    end

    it "finds who a note says you spoke to" do
      job("Netflix").notes.create!(tag: :recruiter_call, spoke_to: "Dana Whitfield")

      expect(search("whitfield")).to eq(["Netflix"])
    end

    it "finds the words in a note" do
      job("Netflix").notes.create!(tag: :note, body: "Mostly Rails, some Go.")

      expect(search("rails")).to eq(["Netflix"])
    end

    it "finds a status" do
      job("Netflix", status: :rejected)
      job("Anrok")

      expect(search("rejected")).to eq(["Netflix"])
    end

    it "finds what kind of thing a note was" do
      job("Netflix").notes.create!(tag: :take_home, body: "Two hours.")
      job("Anrok")

      expect(search("take-home")).to eq(["Netflix"])
    end

    it "finds a link" do
      job("Samsara", url: "https://www.samsara.com/company/careers/roles/7588828")

      expect(search("7588828")).to eq(["Samsara"])
    end

    it "finds where the listing came from" do
      job("TheLadders", source: "LinkedIn")

      expect(search("linkedin")).to eq(["TheLadders"])
    end
  end

  describe "fuzzy matching" do
    it "forgives a typo in the company name" do
      job("Netflix")

      expect(search("netflx")).to eq(["Netflix"])
    end

    it "forgives a typo in one word of a longer name" do
      job("Corporate Tools")

      expect(search("corprate")).to eq(["Corporate Tools"])
    end

    it "still tolerates a slip in a short name" do
      job("Visa")

      expect(search("vsa")).to eq(["Visa"])
    end

    # Fuzzy is for names, not paragraphs — a near-miss inside notes is noise.
    it "does not fuzzy-match the body of a note" do
      job("Netflix").notes.create!(tag: :note, body: "Mostly Rails.")

      expect(search("railz")).to be_empty
    end

    it "finds nothing for a word that simply isn't there" do
      job("Netflix")

      expect(search("zebra")).to be_empty
    end
  end

  describe "several words" do
    # A second word narrows. Treating it as "either" would hand back more than
    # the first word did, which is not what typing more means.
    it "requires every word to land somewhere" do
      netflix = job("Netflix", role: "Staff Engineer")
      netflix.notes.create!(tag: :applied)
      job("Anrok", role: "Staff Engineer")

      expect(search("netflix staff")).to eq(["Netflix"])
      expect(search("netflix plumber")).to be_empty
    end
  end

  describe "composing with the status filter" do
    it "ranks only within what the filter left" do
      job("Netflix", status: :rejected)
      live = job("Netflix Games")
      live.notes.create!(tag: :applied)

      expect(search("netflix", scope: user.job_applications.live)).to eq(["Netflix Games"])
    end
  end

  it "hands back everything, untouched, for a blank query" do
    job("Netflix")
    job("Anrok")

    expect(described_class.call(user.job_applications.ordered, "  ").size).to eq(2)
  end
end
