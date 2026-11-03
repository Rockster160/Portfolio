require "rails_helper"

# A calendar that fails to sync shows "Never synced" forever, so a sync
# tolerates a missing `timezone` and a failing get_calendar, and a real failure
# is re-raised for Sidekiq to retry.
RSpec.describe GoogleCalendarSyncWorker do
  let(:user) { create(:user) }
  let(:google_account) {
    GoogleAccount.create!(user: user, email: "w@example.com", access_token: "t", refresh_token: "r")
  }
  let(:agenda) {
    create(:agenda, user: user, source: :google, external_id: "cal-w",
           google_account: google_account)
  }
  let(:api) { instance_double(Oauth::GoogleApi) }

  before do
    # #perform returns immediately outside production, and every behavior below
    # is about what it does when it actually runs. Slack goes out on the same
    # guard, so hold that too.
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(::SlackNotifier).to receive(:notify)
    allow(Oauth::GoogleApi).to receive(:for_account).with(google_account).and_return(api)
    allow(api).to receive(:get_calendar).and_return(nil)
    # ensure_watch! kicks off after the first successful sync; stub the
    # downstream watch.start! so these specs don't try to reach Google.
    allow(::GoogleCalendar::WatchManager).to receive(:start!).and_return(nil)
  end

  it "completes a sync even when the get_calendar call raises a non-RestClient error" do
    # Simulate any of: NoMethodError (missing column), connection blip,
    # programmer error in tz handling. Sync MUST still set synced_at.
    allow(api).to receive(:get_calendar).and_raise(StandardError, "boom")
    allow(api).to receive(:list_events).and_return({ items: [], nextSyncToken: "tok-1" })

    described_class.new.perform(agenda.id)
    expect(agenda.reload.synced_at).to be_present
  end

  it "completes a sync even when @agenda.timezone access itself raises (column missing)" do
    # Simulates the pre-migration state: `agenda.timezone` raises NoMethodError.
    allow_any_instance_of(Agenda).to receive(:has_attribute?).with(:timezone).and_return(false)
    allow(api).to receive(:list_events).and_return({ items: [], nextSyncToken: "tok-2" })

    described_class.new.perform(agenda.id)
    expect(agenda.reload.synced_at).to be_present
  end

  describe "failure surfacing" do
    it "re-raises a sync failure so Sidekiq retries it, logging it on the way" do
      [NoMethodError.new("undefined method `timezone' for #<Agenda>"), StandardError.new("unexpected")].each { |error|
        allow(api).to receive(:list_events).and_raise(error)
        allow(Rails.logger).to receive(:error)

        expect { described_class.new.perform(agenda.id) }.to raise_error(error.class)
        expect(Rails.logger).to have_received(:error).at_least(:once)
      }
    end
  end
end
