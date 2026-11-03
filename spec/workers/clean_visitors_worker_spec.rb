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
    # A cache entry and a dashboard row are written FOR a guest by whatever page
    # it landed on, so neither says the account was used; neither table has a
    # foreign key to `users`, so they are cleared with the account. Anything else
    # the guest owns keeps it, including on a has_many with no dependent option.
    it "deletes aged guests that own nothing, keeping owners, new guests and real accounts" do
      empty = make_guest
      cache_only = make_guest
      UserCache.create!(user: cache_only, key: "anything", data: { a: 1 })
      dashboard_only = make_guest
      UserDashboard.create!(user: dashboard_only)

      fresh = make_guest(created_at: 1.day.ago)
      real = FactoryBot.create(:user, phone: "5559990201").tap { |u| u.update_column(:created_at, 2.years.ago) }
      real_cache = UserCache.create!(user: real, key: "anything", data: { a: 1 })
      task_owner = make_guest
      Task.create!(user: task_owner, name: "Guest task", listener: "tell:guest", code: "// noop")
      event_owner = make_guest
      ActionEvent.create!(user: event_owner, name: "Coffee", timestamp: 2.weeks.ago)
      cache_and_task = make_guest
      UserCache.create!(user: cache_and_task, key: "anything", data: { a: 1 })
      Task.create!(user: cache_and_task, name: "Held", listener: "tell:held", code: "// noop")

      expect { described_class.new.perform }.to change(User, :count).by(-3)

      gone = [empty, cache_only, dashboard_only].map(&:id)
      expect(User.where(id: gone)).to be_empty
      expect(UserCache.where(user_id: gone)).to be_empty
      expect(UserDashboard.where(user_id: gone)).to be_empty

      kept = [fresh, real, task_owner, event_owner, cache_and_task].map(&:id)
      expect(User.where(id: kept).count).to eq(kept.size)
      expect(UserCache.exists?(real_cache.id)).to be(true)
      expect(UserCache.where(user_id: cache_and_task.id)).to be_present
    end

    it "accepts a shorter retention for draining a backlog" do
      make_guest(created_at: 3.days.ago)

      expect { described_class.new.perform }.not_to change(User, :count)
      expect { described_class.new.perform(1) }.to change(User, :count).by(-1)
    end
  end

  describe "ip visits" do
    it "forgets IPs that visited once and never came back, keeping returners and recent one-offs" do
      stale = make_visit("203.0.113.20", count: 1, last_seen: (described_class::IP_RETENTION.ago - 1.day))
      returner = make_visit("203.0.113.21", count: 2, last_seen: 2.years.ago)
      recent = make_visit("203.0.113.22", count: 1, last_seen: 1.day.ago)

      described_class.new.perform

      expect(IpVisit.exists?(stale.id)).to be(false)
      expect(IpVisit.exists?(returner.id)).to be(true)
      expect(IpVisit.exists?(recent.id)).to be(true)
    end

    # Neither sweep's failure may abort the other.
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
  end

  describe "ownership coverage" do
    subject(:columns) { described_class.new.send(:child_columns) }

    # Some tables have a real foreign key to users but no has_many on User, so
    # the association list alone would miss them and their (NO ACTION)
    # constraint would abort the delete instead.
    it "covers custom foreign keys and association-less references, not through or belongs_to" do
      expect(columns).to include(
        ["chores", "created_by_user_id"],
        ["chore_transfers", "from_user_id"],
        ["oauth_access_tokens", "resource_owner_id"],
        ["buddy_memories", "user_id"],
        ["buddy_watches", "user_id"],
        ["chore_households", "owner_user_id"],
        ["household_icons", "uploaded_by_user_id"],
      )
      expect(columns.map(&:first)).not_to include("lists")
      expect(columns).not_to include(["chore_households", "id"])
    end
  end
end
