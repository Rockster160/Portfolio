require "rails_helper"

RSpec.describe Agenda do
  let(:user) { create(:user) }

  describe "source enum" do
    it "defaults to :user and is not managed_externally?" do
      agenda = create(:agenda, user: user)
      expect(agenda.source).to eq("user")
      expect(agenda).not_to be_managed_externally
    end

    it "marks :google-source agendas as managed_externally?" do
      agenda = create(:agenda, user: user, source: :google, external_id: "cal-1")
      expect(agenda.source).to eq("google")
      expect(agenda).to be_managed_externally
    end
  end

  describe "schema columns" do
    it "has sync_token, synced_at, watch_* columns" do
      expect(Agenda.column_names).to include(
        "source", "external_id", "sync_token", "synced_at",
        "watch_channel_id", "watch_resource_id", "watch_expires_at"
      )
    end

    it "external_uid + external_etag exist on items and schedules" do
      expect(AgendaItem.column_names).to include("external_uid", "external_etag", "external_updated_at")
      expect(AgendaSchedule.column_names).to include("external_uid", "external_etag", "external_updated_at")
    end

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

    it "is true for an externally-managed agenda with no channel and no recent failure" do
      expect(agenda.needs_watch?).to be(true)
    end

    it "is false when a channel is already running" do
      agenda.update!(watch_channel_id: "ch")
      expect(agenda.needs_watch?).to be(false)
    end

    it "is false during the failure cooldown" do
      agenda.update!(watch_failed_at: 1.hour.ago)
      expect(agenda.needs_watch?).to be(false)
    end

    it "is true again after the cooldown elapses" do
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
