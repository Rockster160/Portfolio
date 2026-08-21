require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  describe "csrf" do
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

  describe "the perma-safe ban" do
    controller do
      def index
        head :ok
      end
    end

    let(:banned_ip) { "203.0.113.7" }

    before do
      request.remote_addr = banned_ip
      BannedIp.create!(ip: banned_ip, whitelisted: false)
      User.find_or_create_by!(id: 58_128) { |u| u.username = "chelsea"; u.password = "password123"; u.password_confirmation = "password123" }
      User.find_or_create_by!(id: 4) { |u| u.username = "eve"; u.password = "password123"; u.password_confirmation = "password123" }
    end

    it "blocks a banned IP for a non-perma-safe user" do
      user = User.create!(username: "randobehindhomeip", password: "password123", password_confirmation: "password123")
      sign_in(user)
      get :index
      expect(response).to have_http_status(:unauthorized)
    end

    it "lets Chelsea through even when the shared home IP is banned" do
      sign_in(User.chelsea)
      get :index
      expect(response).to have_http_status(:ok)
    end

    it "lets Eve through even when the shared home IP is banned" do
      sign_in(User.eve)
      get :index
      expect(response).to have_http_status(:ok)
    end

    it "treats perma-safe users as whitelisted so they never get banned" do
      sign_in(User.chelsea)
      get :index
      expect(controller.send(:ip_whitelisted?)).to be(true)
    end
  end
end
