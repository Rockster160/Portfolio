require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  controller do
    skip_before_action :verify_authenticity_token, raise: false
    before_action :force_csrf_failure, only: :create

    def create
      render json: { ok: true }
    end

    private

    def force_csrf_failure
      raise ActionController::InvalidAuthenticityToken
    end
  end

  before do
    routes.draw { post "anonymous" => "anonymous#create" }
    allow(Rails.env).to receive(:production?).and_return(true)
    described_class.send(:rescue_from, ::ActionController::InvalidAuthenticityToken, with: :handle_stale_csrf)
  end

  describe "stale CSRF token handling" do
    let(:user) { create(:user) }

    it "returns 422 JSON with stale_csrf instead of re-raising for a normal user" do
      sign_in user
      allow(controller).to receive(:current_ip_spamming?).and_return(false)

      post :create, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to eq("error" => "stale_csrf")
    end

    it "stays silent for a single stale-token hit (normal client recovery)" do
      sign_in user
      allow(controller).to receive(:current_ip_spamming?).and_return(false)
      allow(SlackNotifier).to receive(:notify)
      Rails.cache.clear

      post :create, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(SlackNotifier).not_to have_received(:notify)
    end

    it "Slacks once when the same user hits stale CSRF repeatedly (recovery is broken)" do
      sign_in user
      allow(controller).to receive(:current_ip_spamming?).and_return(false)
      allow(SlackNotifier).to receive(:notify)
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)

      5.times { post :create, format: :json }

      expect(SlackNotifier).to have_received(:notify).once
    end

    it "still bans + re-raises (so ExceptionNotifier fires) when the IP is actually spamming" do
      sign_in user
      allow(controller).to receive(:current_ip_spamming?).and_return(true)
      allow(controller).to receive(:ip_whitelisted?).and_return(false)
      allow(BannedIp).to receive(:find_or_create_by)
      allow(SlackNotifier).to receive(:notify)

      expect {
        post :create, format: :json
      }.to raise_error(ActionController::InvalidAuthenticityToken)

      expect(BannedIp).to have_received(:find_or_create_by).with(ip: controller.send(:current_ip))
    end
  end
end
