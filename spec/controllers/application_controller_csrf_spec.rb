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

      it "returns 422 stale_csrf JSON for a normal user, silently on a single hit" do
        sign_in user
        allow(controller).to receive(:current_ip_spamming?).and_return(false)
        allow(SlackNotifier).to receive(:notify)
        Rails.cache.clear

        post :create, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq("error" => "stale_csrf")
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

      it "never bans a signed-in user even while the shared IP is spamming (stale token = refresh)" do
        sign_in user
        allow(controller).to receive_messages(current_ip_spamming?: true, ip_whitelisted?: false)
        allow(BannedIp).to receive(:find_or_create_by)
        allow(SlackNotifier).to receive(:notify)

        post :create, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(BannedIp).not_to have_received(:find_or_create_by)
      end

      it "bans + re-raises an anonymous client that keeps failing CSRF while spamming" do
        allow(controller).to receive_messages(current_ip_spamming?: true, ip_whitelisted?: false)
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

    it "lets a perma-safe user through the banned shared IP, treated as whitelisted" do
      sign_in(User.chelsea)
      get :index
      expect(response).to have_http_status(:ok)
      expect(controller.send(:ip_whitelisted?)).to be(true)
    end

    it "lets Eve through the banned shared IP too" do
      sign_in(User.eve)
      get :index
      expect(response).to have_http_status(:ok)
    end
  end
end
