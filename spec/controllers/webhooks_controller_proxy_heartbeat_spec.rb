require "rails_helper"

# The relay on the home Mac posts here every couple of minutes. Its whole job is
# to make "is that specific machine alive?" answerable from prod — the question
# the network walk can't settle, since a sleeping Mac and a mis-forwarded router
# both present as a dead port.
RSpec.describe WebhooksController, type: :controller do
  let(:user) { User.me }

  before { DataStorage.where(name: ProxyRequest::RELAY_SEEN_AT_KEY).delete_all }

  describe "POST #proxy_heartbeat" do
    it "stamps the check-in for the signed-in owner" do
      allow(controller).to receive(:current_user).and_return(user)

      post :proxy_heartbeat

      expect(response).to have_http_status(:ok)
      expect(ProxyRequest.relay_last_seen_at).to be_within(5.seconds).of(Time.current)
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
