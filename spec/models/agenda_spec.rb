# == Schema Information
#
# Table name: agendas
#
#  id                 :bigint           not null, primary key
#  user_id            :bigint           not null
#  name               :string           not null
#  parameterized_name :string           not null
#  color              :string
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  source             :integer          default("user"), not null
#  external_id        :text
#  sync_token         :text
#  synced_at          :datetime
#  watch_channel_id   :text
#  watch_resource_id  :text
#  watch_expires_at   :datetime
#  watch_failed_at    :datetime
#  google_account_id  :bigint
#  sync_reason        :string
#  read_only          :boolean          default(FALSE), not null
#

require "rails_helper"

RSpec.describe Agenda do
  describe "the model" do
    let(:user) { create(:user) }

    it "creates with parameterized_name and default color" do
      agenda = described_class.create!(user: user, name: "My Work Stuff")
      expect(agenda.parameterized_name).to eq("my-work-stuff")
      expect(agenda.color).to eq(Agenda::DEFAULT_COLOR)
    end

    it "uniqueness of parameterized_name scoped to user" do
      described_class.create!(user: user, name: "Work")
      dup = described_class.new(user: user, name: "Work")
      expect(dup).not_to be_valid

      other_user = create(:user, phone: "5550000002")
      other = described_class.new(user: other_user, name: "Work")
      expect(other).to be_valid
    end

    # Whose days these events are, which is narrower than who can see them.
    # Drives who a leave-by / heavy-traffic / time-to-go alert reaches.
    describe "#subject_users" do
      let(:partner) { create(:user, phone: "5550000101") }
      let(:agenda) { described_class.create!(user: user, name: "Work") }

      # An editor can ADD to someone's work calendar without it being their
      # day, so only a co-owner joins the owner; access_users is the wider set.
      it "is the owner alone until someone else is a co-owner", :aggregate_failures do
        third = create(:user, phone: "5550000102")
        expect(agenda.subject_users).to contain_exactly(user)

        share = agenda.agenda_shares.create!(user: partner, permission: :viewer)
        expect(agenda.subject_users).to contain_exactly(user)

        share.update!(permission: :editor)
        expect(agenda.reload.subject_users).to contain_exactly(user)
        expect(agenda.access_users).to contain_exactly(user, partner)

        share.update!(permission: :owner)
        agenda.agenda_shares.create!(user: third, permission: :viewer)
        expect(agenda.reload.subject_users).to contain_exactly(user, partner)
      end
    end

    describe "#items_for" do
      let(:agenda) { create(:agenda, user: user) }

      it "returns persisted rows on the matching date" do
        target_date = Date.current + 30.days
        target = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: Time.zone.local(target_date.year, target_date.month, target_date.day, 8, 0))
        _other = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: Time.zone.local(target_date.year, target_date.month, target_date.day, 8, 0) + 2.days)
        expect(agenda.items_for(target_date).to_a).to eq([target])
      end

      it "merges in phantoms from each matching schedule" do
        sched = create(:agenda_schedule, agenda: agenda, name: "Standup",
          kind: "task", start_time: "09:00",
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
        items = agenda.items_for(Date.current + 50.days)
        phantom = items.find(&:phantom?)
        expect(phantom).to be_present
        expect(phantom.name).to eq("Standup")
        expect(phantom.agenda_schedule_id).to eq(sched.id)
      end

      # The clock is pinned because the schedule is monthly on the 15th and
      # MATERIALIZE_WINDOW is 30 hours: run this on the 14th and the very next
      # occurrence is written as a real row, so the count assertion fails for
      # reasons that have nothing to do with a century from now.
      it "renders schedules 100 years into the future without materialization" do
        travel_to(Time.zone.parse("2026-03-02 09:00")) {
          create(:agenda_schedule, agenda: agenda, name: "Birthday",
            kind: "event", start_time: "10:00", duration_minutes: 60,
            recurrence: { "freq" => "monthly", "by_month_day" => [15] },
            starts_on: Date.current)

          future = Date.current.change(day: 15) + 100.years
          items = agenda.items_for(future)
          expect(items.size).to eq(1)
          expect(items.first).to be_phantom
          expect(AgendaItem.count).to eq(0)
        }
      end

      it "prefers the real row over a phantom when a recurring instance has been materialized" do
        sched = create(:agenda_schedule, agenda: agenda, kind: "task",
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
        target = Date.current + 3.days
        sched.phantom_for(target).materialize!(name: "Customized")

        items = agenda.items_for(target)
        expect(items.size).to eq(1)
        expect(items.first.name).to eq("Customized")
        expect(items.first).not_to be_phantom
      end

      it "suppresses the phantom on a detached override's original_start_at date even when the override now lives on a different day" do
        Timecop.freeze(Time.zone.local(2026, 6, 1, 10, 0)) do
          sched = create(:agenda_schedule, agenda: agenda, kind: "event",
            name: "Sync", start_time: "10:00", duration_minutes: 30,
            recurrence: { "freq" => "monthly", "by_set_pos" => 3, "by_day" => ["tue"] },
            starts_on: Date.new(2026, 3, 17))

          # User moved the Jun 16 (3rd Tue) occurrence to Jun 15 (Mon).
          moved_to = Time.zone.local(2026, 6, 15, 9, 0)
          original = Time.zone.local(2026, 6, 16, 10, 0)
          override = create(:agenda_item, agenda: agenda, kind: "event",
            agenda_schedule: sched, detached_at: Time.current,
            original_start_at: original,
            start_at: moved_to, end_at: moved_to + 30.minutes,
            name: "Sync")

          june_items = agenda.items_for_range(Date.new(2026, 6, 14), Date.new(2026, 6, 17))
          # Should see exactly ONE Sync: the override on Mon Jun 15. No phantom on Jun 16.
          sync_items = june_items.select { |i| i.name == "Sync" }
          expect(sync_items.map(&:id)).to eq([override.id])
          expect(sync_items.none?(&:phantom?)).to be true
        end
      end
    end

    describe "#carry_over_items" do
      let(:agenda) { create(:agenda, user: user) }

      it "returns past-due uncompleted tasks only (not events)" do
        Timecop.freeze(Time.zone.local(2026, 5, 13, 10, 0)) do
          overdue_task = create(:agenda_item, agenda: agenda, kind: "task",
            start_at: 2.days.ago, completed_at: nil)
          _completed = create(:agenda_item, agenda: agenda, kind: "task",
            start_at: 2.days.ago, completed_at: 1.day.ago)
          _past_event = create(:agenda_item, agenda: agenda, kind: "event",
            start_at: 2.days.ago, end_at: 2.days.ago + 1.hour)
          _today_task = create(:agenda_item, agenda: agenda, kind: "task",
            start_at: Time.current)

          expect(agenda.carry_over_items.to_a).to eq([overdue_task])
        end
      end

      it "keeps a carry-over task that was completed today (so it stays crossed-out, not vanishing)" do
        Timecop.freeze(Time.zone.local(2026, 5, 13, 10, 0)) do
          completed_today = create(:agenda_item, agenda: agenda, kind: "task",
            start_at: 2.days.ago, completed_at: Time.current)
          still_open = create(:agenda_item, agenda: agenda, kind: "task",
            start_at: 1.day.ago, completed_at: nil)
          _completed_yesterday = create(:agenda_item, agenda: agenda, kind: "task",
            start_at: 3.days.ago, completed_at: 1.day.ago)

          expect(agenda.carry_over_items.to_a).to match_array([completed_today, still_open])
        end
      end
    end
  end

  describe "google" do
    let(:user) { create(:user) }

    it "is managed externally only when it comes from Google" do
      expect(create(:agenda, user: user)).not_to be_managed_externally
      expect(create(:agenda, user: user, source: :google, external_id: "cal-1")).to be_managed_externally
    end

    describe "external_id uniqueness" do
      it "lets the same external_id appear under different google_accounts (shared calendar)" do
        account_a = GoogleAccount.create!(user: user, email: "a@x.com")
        account_b = GoogleAccount.create!(user: user, email: "b@x.com")
        create(
          :agenda, user: user, source: :google, external_id: "shared@group",
          google_account: account_a
        )
        dup = build(
          :agenda, user: user, source: :google, external_id: "shared@group",
          google_account: account_b
        )
        dup.parameterized_name = "shared-group-b"
        expect { dup.save!(validate: false) }.not_to raise_error
      end

      it "still blocks duplicates within the same google_account" do
        account = GoogleAccount.create!(user: user, email: "c@x.com")
        create(
          :agenda, user: user, source: :google, external_id: "primary",
          google_account: account
        )
        dup = build(
          :agenda, user: user, source: :google, external_id: "primary",
          google_account: account
        )
        dup.parameterized_name = "primary-2"
        expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    describe ".due_for_watch_renewal" do
      it "includes externally-managed agendas whose watch expires within the lead window" do
        soon = create(
          :agenda, user: user, source: :google, external_id: "soon",
          watch_channel_id: "ch-1", watch_resource_id: "res-1",
          watch_expires_at: 6.hours.from_now
        )
        later = create(
          :agenda, user: user, source: :google, external_id: "later",
          watch_channel_id: "ch-2", watch_resource_id: "res-2",
          watch_expires_at: 3.days.from_now
        )
        user_agenda = create(:agenda, user: user, source: :user) # not externally managed

        due = Agenda.due_for_watch_renewal
        expect(due).to include(soon)
        expect(due).not_to include(later)
        expect(due).not_to include(user_agenda)
      end

      it "excludes agendas in the watch-failure cooldown window" do
        cooling_down = create(
          :agenda, user: user, source: :google, external_id: "cooling",
          watch_channel_id: "ch", watch_resource_id: "res",
          watch_expires_at: 6.hours.from_now,
          watch_failed_at: 1.hour.ago
        )
        expect(Agenda.due_for_watch_renewal).not_to include(cooling_down)
      end
    end

    describe "#needs_watch?" do
      let(:agenda) { create(:agenda, user: user, source: :google, external_id: "cal-x") }

      it "is true with no channel and no recent failure, false while a channel runs or cooling down" do
        expect(agenda.needs_watch?).to be(true)
        agenda.update!(watch_channel_id: "ch")
        expect(agenda.needs_watch?).to be(false)
        agenda.update!(watch_channel_id: nil, watch_failed_at: 1.hour.ago)
        expect(agenda.needs_watch?).to be(false)
        agenda.update!(watch_failed_at: 2.days.ago)
        expect(agenda.needs_watch?).to be(true)
      end
    end

    describe ".needing_reauth" do
      it "returns externally-managed agendas whose GoogleAccount needs reauth" do
        bad_account = GoogleAccount.create!(
          user: user, email: "bad@x.com", reauth_required_at: 1.minute.ago,
        )
        ok_account = GoogleAccount.create!(user: user, email: "ok@x.com")
        needs = create(
          :agenda, user: user, source: :google, external_id: "needs",
          google_account: bad_account
        )
        _ok = create(
          :agenda, user: user, source: :google, external_id: "ok",
          google_account: ok_account
        )
        _user_agenda = create(:agenda, user: user, source: :user)

        expect(Agenda.needing_reauth).to contain_exactly(needs)
      end
    end
  end

  describe "the color cascade" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user, color: "#0160FF") }

    it "uses an item's own color, then its schedule's, then the agenda's", :aggregate_failures do
      colored = create(:agenda_schedule, agenda: agenda, color: "#ff8800")
      plain = create(:agenda_schedule, agenda: agenda, color: nil)
      expect(colored.display_color).to eq("#ff8800")
      expect(plain.display_color).to eq("#0160FF")

      expect(create(:agenda_item, agenda: agenda, color: "#00ff00").display_color).to eq("#00ff00")
      from_schedule = colored.agenda_items.create!(agenda: agenda, kind: "task",
        name: "X", start_at: 1.hour.from_now, color: nil)
      expect(from_schedule.display_color).to eq("#ff8800")
      expect(create(:agenda_item, agenda: agenda, color: nil).display_color).to eq("#0160FF")
    end

    describe "phantom inherits color from its schedule" do
      it "is the schedule's color even without an item.color" do
        sched = create(:agenda_schedule, agenda: agenda,
          recurrence: { "freq" => "daily" }, starts_on: Date.current,
          color: "#abcdef")
        phantom = sched.phantom_for(Date.current + 3)
        expect(phantom.color).to eq("#abcdef")
        expect(phantom.display_color).to eq("#abcdef")
      end
    end
  end

  describe "query efficiency" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    def count_queries
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) {
        sql = payload[:sql]
        next if sql.match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i)
        next if payload[:name] == "SCHEMA"

        queries << sql
      }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries
    end

    it "reads a year or a single day in 2 queries (items + schedules), however many schedules" do
      create_list(:agenda_schedule, 10, agenda: agenda,
        recurrence: { "freq" => "daily" }, starts_on: Date.current)

      year   = count_queries { agenda.items_for_range(Date.current, Date.current + 365.days).to_a }
      single = count_queries { agenda.items_for(Date.current).to_a }

      expect([year.size, single.size]).to eq([2, 2])
    end

    it "stays at 2 queries as the range grows from 1 day to 100 years" do
      create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "weekly", "by_day" => %w[mon] }, starts_on: Date.current)

      one_day = count_queries { agenda.items_for_range(Date.current, Date.current).to_a }
      century = count_queries { agenda.items_for_range(Date.current, Date.current + 100.years).to_a }

      expect([one_day.size, century.size]).to eq([2, 2])
    end
  end
end
