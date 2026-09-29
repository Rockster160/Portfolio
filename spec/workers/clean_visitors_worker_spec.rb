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
      ActionEvent.create!(user: guest, name: "Coffee", timestamp: 2.weeks.ago)

      expect { described_class.new.perform }.not_to change(User, :count)
    end

    # A cache entry and a dashboard row are written FOR a guest by whatever page
    # it landed on, so neither says the account was used. Holding accounts on
    # them left 531 sitting months past retention owning nothing else.
    it "sweeps a guest held up only by a cache entry" do
      guest = make_guest
      cache = UserCache.create!(user: guest, key: "anything", data: { a: 1 })

      expect { described_class.new.perform }.to change(User, :count).by(-1)
      expect(UserCache.exists?(cache.id)).to be(false)
    end

    it "sweeps a guest held up only by a dashboard row" do
      guest = make_guest
      dashboard = UserDashboard.create!(user: guest)

      expect { described_class.new.perform }.to change(User, :count).by(-1)
      expect(UserDashboard.exists?(dashboard.id)).to be(false)
    end

    # Neither table has a foreign key to `users`, so skipping the check without
    # clearing the rows would leave them pointing at an id that is gone.
    it "leaves no derived rows behind pointing at a deleted account" do
      guest = make_guest
      UserCache.create!(user: guest, key: "anything", data: { a: 1 })
      UserDashboard.create!(user: guest)

      described_class.new.perform

      expect(UserCache.where(user_id: guest.id)).to be_empty
      expect(UserDashboard.where(user_id: guest.id)).to be_empty
    end

    # The derived rows are not a licence to delete an account that was used.
    it "still keeps a guest whose cache sits beside a real record" do
      guest = make_guest
      UserCache.create!(user: guest, key: "anything", data: { a: 1 })
      Task.create!(user: guest, name: "Held", listener: "tell:held", code: "// noop")

      expect { described_class.new.perform }.not_to change(User, :count)
      expect(UserCache.where(user_id: guest.id)).to be_present
    end

    # A real account's cache is not swept by a sweep aimed at guests.
    it "leaves a real account's cache alone" do
      user = travel_to(2.years.ago) { FactoryBot.create(:user, phone: "5559990202") }
      cache = UserCache.create!(user: user, key: "anything", data: { a: 1 })
      make_guest

      described_class.new.perform

      expect(UserCache.exists?(cache.id)).to be(true)
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

  describe "draining a backlog" do
    it "comes back for the rest when it hits the delete cap" do
      stub_const("#{described_class}::MAX_GUEST_DELETES", 2)
      3.times { make_guest }

      expect(described_class).to receive(:perform_in).with(described_class::RESUME_DELAY, nil)

      described_class.new.perform
    end

    it "carries a shortened retention into the follow-up run" do
      stub_const("#{described_class}::MAX_GUEST_DELETES", 2)
      3.times { make_guest(created_at: 3.days.ago) }

      expect(described_class).to receive(:perform_in).with(described_class::RESUME_DELAY, 1)

      described_class.new.perform(1)
    end

    it "does not reschedule once it has drained everything" do
      make_guest

      expect(described_class).not_to receive(:perform_in)

      described_class.new.perform
    end
  end

  describe "vacuum" do
    let(:connection) { ActiveRecord::Base.connection }

    it "vacuums the tables it deleted from once the sweep is finished" do
      make_guest
      allow(connection).to receive(:transaction_open?).and_return(false)
      allow(connection).to receive(:execute)

      described_class.new.perform

      expect(connection).to have_received(:execute).with(/VACUUM ANALYZE "users"/)
      expect(connection).to have_received(:execute).with(/VACUUM ANALYZE "ip_visits"/)
    end

    it "skips the vacuum when there was nothing to delete" do
      allow(connection).to receive(:transaction_open?).and_return(false)

      expect(connection).not_to receive(:execute).with(/VACUUM/)

      described_class.new.perform
    end

    it "skips the vacuum mid-drain, so resumed chunks don't each pay for it" do
      stub_const("#{described_class}::MAX_GUEST_DELETES", 2)
      3.times { make_guest }
      allow(described_class).to receive(:perform_in)
      allow(connection).to receive(:transaction_open?).and_return(false)

      expect(connection).not_to receive(:execute).with(/VACUUM/)

      described_class.new.perform
    end

    # VACUUM raises inside a transaction, and specs always run in one.
    it "stays silent when it cannot vacuum" do
      make_guest

      expect { described_class.new.perform }.not_to raise_error
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
