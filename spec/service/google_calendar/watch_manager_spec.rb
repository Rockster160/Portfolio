require "rails_helper"

RSpec.describe GoogleCalendar::WatchManager do
  let(:user) { create(:user) }
  let(:google_account) {
    GoogleAccount.create!(user: user, email: "wm@example.com", access_token: "t", refresh_token: "r")
  }
  let(:agenda) {
    create(
      :agenda, user: user, source: :google, external_id: "cal-1",
      google_account: google_account
    )
  }
  let(:api) { instance_double(Oauth::GoogleApi) }

  before { allow(Oauth::GoogleApi).to receive(:for_account).with(google_account).and_return(api) }

  describe ".start!" do
    it "registers a watch channel and persists its identity" do
      expiration_ms = ((7.days.from_now).to_f * 1000).to_i
      allow(api).to receive(:watch_events).and_return({
        id:         instance_of(String),
        resourceId: "res-xyz",
        expiration: expiration_ms.to_s,
      })

      described_class.start!(agenda)
      agenda.reload
      expect(agenda.watch_channel_id).to be_present
      expect(agenda.watch_resource_id).to eq("res-xyz")
      expect(agenda.watch_expires_at).to be_within(2.seconds).of(Time.zone.at(expiration_ms / 1000.0))
    end

    it "stops any previous channel before starting a fresh one" do
      agenda.update!(
        watch_channel_id: "old-ch", watch_resource_id: "old-res",
        watch_expires_at: 1.day.from_now
      )
      allow(api).to receive(:stop_watch)
      allow(api).to receive(:watch_events).and_return({
        id: "new-ch", resourceId: "new-res", expiration: "0"
      })

      described_class.start!(agenda)
      expect(api).to have_received(:stop_watch).with(channel_id: "old-ch", resource_id: "old-res")
    end
  end

  describe ".stop!" do
    it "calls channels.stop and clears the columns" do
      agenda.update!(
        watch_channel_id: "ch-1", watch_resource_id: "res-1",
        watch_expires_at: 1.day.from_now
      )
      allow(api).to receive(:stop_watch)

      described_class.stop!(agenda)
      expect(api).to have_received(:stop_watch).with(channel_id: "ch-1", resource_id: "res-1")
      agenda.reload
      expect(agenda.watch_channel_id).to be_nil
      expect(agenda.watch_resource_id).to be_nil
      expect(agenda.watch_expires_at).to be_nil
    end

    it "swallows 404/410 from a channel that's already gone server-side" do
      agenda.update!(watch_channel_id: "ch-1", watch_resource_id: "res-1")
      allow(api).to receive(:stop_watch).and_raise(
        RestClient::NotFound.new(instance_double(RestClient::Response, code: 404, body: "")),
      )

      expect { described_class.stop!(agenda) }.not_to raise_error
      expect(agenda.reload.watch_channel_id).to be_nil
    end
  end

  describe ".token_for" do
    it "returns a stable HMAC bound to the agenda id" do
      expect(described_class.token_for(agenda)).to eq(described_class.token_for(agenda.reload))
    end

    it "differs across agendas" do
      other = create(:agenda, user: user, source: :google, external_id: "cal-2")
      expect(described_class.token_for(agenda)).not_to eq(described_class.token_for(other))
    end
  end

  describe "watch failure handling" do
    it "captures Forbidden into watch_failed_at and returns nil" do
      err = RestClient::Forbidden.new(instance_double(RestClient::Response, code: 403, body: "{}"))
      allow(api).to receive(:watch_events).and_raise(err)

      result = described_class.start!(agenda)
      expect(result).to be_nil
      expect(agenda.reload.watch_failed_at).to be_present
      expect(agenda.watch_channel_id).to be_nil
    end

    it "captures BadRequest the same way (some Google denies use 400)" do
      err = RestClient::BadRequest.new(instance_double(RestClient::Response, code: 400, body: "{}"))
      allow(api).to receive(:watch_events).and_raise(err)

      described_class.start!(agenda)
      expect(agenda.reload.watch_failed_at).to be_present
    end

    it "clears watch_failed_at on a successful start" do
      agenda.update!(watch_failed_at: 1.day.ago)
      allow(api).to receive(:watch_events).and_return({
        id: "ch-1", resourceId: "res-1", expiration: "0"
      })

      described_class.start!(agenda)
      expect(agenda.reload.watch_failed_at).to be_nil
    end
  end
end
