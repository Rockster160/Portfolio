require "rails_helper"

# The relay on the home Mac posts here every couple of minutes. Its whole job is
# to make "is that specific machine alive?" answerable from prod — the question
# the network walk can't settle, since a sleeping Mac and a mis-forwarded router
# both present as a dead port.
RSpec.describe WebhooksController, type: :controller do
  let(:user) { User.me }

  before do
    DataStorage.where(name: [ProxyRequest::RELAY_SEEN_AT_KEY, ProxyRequest::RELAY_LAN_KEY]).delete_all
    allow(TeslaProxyRecoveryWorker).to receive(:perform_async)
  end

  describe "POST #proxy_heartbeat" do
    it "stamps the check-in for the signed-in owner" do
      allow(controller).to receive(:current_user).and_return(user)

      post :proxy_heartbeat

      expect(response).to have_http_status(:ok)
      expect(ProxyRequest.relay_last_seen_at).to be_within(5.seconds).of(Time.current)
    end

    # The address is the point: a hung NIC moves the Mac to a different one
    # while the relay keeps checking in, and prod has no other way to learn it.
    it "records the LAN address the relay reports" do
      allow(controller).to receive(:current_user).and_return(user)

      post :proxy_heartbeat, params: { lan_ip: "192.168.0.160", interface: "en7" }

      expect(ProxyRequest.relay_lan[:ip]).to eq("192.168.0.160")
      expect(ProxyRequest.relay_lan[:interface]).to eq("en7")
    end

    # This check-in is the only moment prod KNOWS the Mac is alive again, so
    # it is where recovery belongs — and it costs nothing while healthy.
    it "kicks off recovery when prod still believes the proxy is down" do
      allow(controller).to receive(:current_user).and_return(user)
      allow(DataStorage).to receive(:[]).and_call_original
      allow(DataStorage).to receive(:[]).with(:tesla_proxy_unreachable).and_return(true)

      post :proxy_heartbeat

      expect(TeslaProxyRecoveryWorker).to have_received(:perform_async)
    end

    it "does not kick off recovery while everything is healthy" do
      allow(controller).to receive(:current_user).and_return(user)
      allow(DataStorage).to receive(:[]).and_call_original
      allow(DataStorage).to receive(:[]).with(:tesla_proxy_unreachable).and_return(false)

      post :proxy_heartbeat

      expect(TeslaProxyRecoveryWorker).not_to have_received(:perform_async)
    end

    # Deliberately loud rather than a quiet :ok. A relay that believes it is
    # checking in while prod records nothing is the exact blind spot this
    # endpoint exists to close, so it has to surface in the relay's log.
    it "401s and records nothing when the caller isn't the owner" do
      allow(controller).to receive(:current_user).and_return(nil)

      post :proxy_heartbeat

      expect(response).to have_http_status(:unauthorized)
      expect(ProxyRequest.relay_last_seen_at).to be_nil
    end
  end
end
