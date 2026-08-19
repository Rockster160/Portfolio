RSpec.describe CleanVisitorsWorker, type: :worker do
  def make_guest(created_at: 2.weeks.ago)
    User.create!(role: :guest).tap { |user| user.update_column(:created_at, created_at) }
  end

  def make_visit(ip, count:, last_seen:)
    IpVisit.create!(
      ip_address: ip, visit_count: count, first_seen_at: last_seen, last_seen_at: last_seen,
    )
  end

  describe "guests" do
    it "deletes aged guests that own nothing" do
      guest = make_guest

      expect { described_class.new.perform }.to change(User, :count).by(-1)
      expect(User.exists?(guest.id)).to be(false)
    end

    it "keeps guests newer than the retention window" do
      make_guest(created_at: 1.day.ago)

      expect { described_class.new.perform }.not_to change(User, :count)
    end

    it "never touches non-guest accounts" do
      FactoryBot.create(:user, phone: "5559990201").update_column(:created_at, 2.years.ago)

      expect { described_class.new.perform }.not_to change(User, :count)
    end

    it "keeps a guest that owns a record" do
      guest = make_guest
      Task.create!(user: guest, name: "Guest task", listener: "tell:guest", code: "// noop")

      expect { described_class.new.perform }.not_to change(User, :count)
      expect(User.exists?(guest.id)).to be(true)
    end

    it "keeps a guest that owns a record on a has_many without a dependent option" do
      guest = make_guest
      UserCache.create!(user: guest, key: "anything", data: { a: 1 })

      expect { described_class.new.perform }.not_to change(User, :count)
    end

    it "separates owners from non-owners inside a single batch" do
      owner = make_guest
      Task.create!(user: owner, name: "Held", listener: "tell:held", code: "// noop")
      empties = Array.new(3) { make_guest }

      expect { described_class.new.perform }.to change(User, :count).by(-3)
      expect(User.exists?(owner.id)).to be(true)
      expect(User.where(id: empties.map(&:id)).count).to eq(0)
    end

    it "accepts a shorter retention for draining a backlog" do
      make_guest(created_at: 3.days.ago)

      expect { described_class.new.perform }.not_to change(User, :count)
      expect { described_class.new.perform(1) }.to change(User, :count).by(-1)
    end
  end

  describe "ip visits" do
    it "forgets IPs that visited once and never came back" do
      stale = make_visit("203.0.113.20", count: 1, last_seen: (described_class::IP_RETENTION.ago - 1.day))

      described_class.new.perform

      expect(IpVisit.exists?(stale.id)).to be(false)
    end

    it "keeps anyone who came back, however long ago" do
      returner = make_visit("203.0.113.21", count: 2, last_seen: 2.years.ago)

      described_class.new.perform

      expect(IpVisit.exists?(returner.id)).to be(true)
    end

    it "keeps a recent one-off, which may still turn into a regular" do
      recent = make_visit("203.0.113.22", count: 1, last_seen: 1.day.ago)

      described_class.new.perform

      expect(IpVisit.exists?(recent.id)).to be(true)
    end

    # The guest sweep used to abort the whole job on an unexpected foreign key;
    # the IP sweep must not inherit that fate, and vice versa.
    it "runs both sweeps in one pass" do
      make_guest
      make_visit("203.0.113.23", count: 1, last_seen: 1.year.ago)

      expect(described_class.new.perform).to eq({ guests: 1, ip_visits: 1 })
    end
  end

  describe "ownership coverage" do
    subject(:columns) { described_class.new.send(:child_columns) }

    it "includes associations declared with a custom foreign key" do
      expect(columns).to include(["chores", "created_by_user_id"])
      expect(columns).to include(["chore_transfers", "from_user_id"])
      expect(columns).to include(["oauth_access_tokens", "resource_owner_id"])
    end

    # These have a real foreign key to users but no has_many on User, so the
    # association list alone would miss them and their (NO ACTION) constraint
    # would abort the delete instead.
    it "includes tables that reference users without a matching association" do
      expect(columns).to include(["buddy_memories", "user_id"])
      expect(columns).to include(["buddy_watches", "user_id"])
      expect(columns).to include(["chore_households", "owner_user_id"])
      expect(columns).to include(["household_icons", "uploaded_by_user_id"])
    end

    it "excludes through associations and the belongs_to side" do
      expect(columns.map(&:first)).not_to include("lists")
      expect(columns).not_to include(["chore_households", "id"])
    end
  end
end
