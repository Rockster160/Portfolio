require "rails_helper"

RSpec.describe WebhooksController, type: :controller do
  describe "POST #google_calendar" do
    let(:user) { create(:user) }
    let!(:agenda) {
      create(
        :agenda, user: user, source: :google, external_id: "cal-1",
        watch_channel_id: "ch-abc", watch_resource_id: "res-abc",
        watch_expires_at: 1.day.from_now
      )
    }
    let(:valid_token) { GoogleCalendar::WatchManager.token_for(agenda) }

    it "enqueues a sync when the headers identify a known channel + matching token" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)
      request.headers["X-Goog-Channel-Id"] = "ch-abc"
      request.headers["X-Goog-Channel-Token"] = valid_token
      request.headers["X-Goog-Resource-State"] = "exists"

      post :google_calendar
      expect(response).to have_http_status(:no_content)
      expect(GoogleCalendarSyncWorker).to have_received(:perform_async).with(agenda.id, "webhook")
    end

    it "ignores the initial 'sync' handshake" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)
      request.headers["X-Goog-Channel-Id"] = "ch-abc"
      request.headers["X-Goog-Channel-Token"] = valid_token
      request.headers["X-Goog-Resource-State"] = "sync"

      post :google_calendar
      expect(response).to have_http_status(:no_content)
      expect(GoogleCalendarSyncWorker).not_to have_received(:perform_async)
    end

    it "rejects unknown channel ids" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)
      request.headers["X-Goog-Channel-Id"] = "nope"
      request.headers["X-Goog-Channel-Token"] = valid_token

      post :google_calendar
      expect(response).to have_http_status(:no_content)
      expect(GoogleCalendarSyncWorker).not_to have_received(:perform_async)
    end

    it "rejects deliveries with a wrong token" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)
      request.headers["X-Goog-Channel-Id"] = "ch-abc"
      request.headers["X-Goog-Channel-Token"] = "forged"
      request.headers["X-Goog-Resource-State"] = "exists"

      post :google_calendar
      expect(response).to have_http_status(:forbidden)
      expect(GoogleCalendarSyncWorker).not_to have_received(:perform_async)
    end
  end
end
