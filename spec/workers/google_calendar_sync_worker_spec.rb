require "rails_helper"

# Critical surface: when a freshly-connected calendar fails to sync, the
# user just sees "Never synced" forever. These specs lock in the
# defensive behaviors that prevent silent failure:
#   * ensure_timezone! tolerates a missing `timezone` column (pre-migration).
#   * perform's rescue keeps the failure from disappearing into Sidekiq's
#     dead queue and tags Slack with an actionable hint.
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
    it "logs + re-raises so Sidekiq retries — and includes a migration hint when the error looks schema-shaped" do
      allow(api).to receive(:list_events).and_raise(NoMethodError, "undefined method `timezone' for #<Agenda>")
      expect(Rails.logger).to receive(:error).with(/missing migration/)
      expect(Rails.logger).to receive(:error).at_least(:once) # backtrace
      expect { described_class.new.perform(agenda.id) }.to raise_error(NoMethodError)
    end

    it "still logs a non-migration failure, with no migration hint" do
      allow(api).to receive(:list_events).and_raise(StandardError, "unexpected")
      expect(Rails.logger).to receive(:error) { |msg|
        expect(msg).to match(/FAILED StandardError/)
        expect(msg).not_to match(/missing migration/)
      }
      expect(Rails.logger).to receive(:error).at_least(:once)
      expect { described_class.new.perform(agenda.id) }.to raise_error(StandardError, "unexpected")
    end
  end
end
