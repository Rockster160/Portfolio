require "rails_helper"

# Inbound Teller webhooks. There's no API key on these requests — the
# `Teller-Signature` HMAC is the only thing standing between the open route and
# a write, so the auth cases matter more than the happy path here.
RSpec.describe WebhooksController, type: :controller do
  let(:secret) { "test_signing_secret" }
  let(:body) {
    {
      id:        "wh_oiffb5cocakqmksbkg000",
      payload:   { enrollment_id: "enr_123", reason: "disconnected.account_locked" },
      timestamp: "2026-08-10T03:49:29Z",
      type:      "enrollment.disconnected",
    }.to_json
  }

  def sign(raw, at: Time.current, key: secret)
    stamp = at.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", key, "#{stamp}.#{raw}")
    "t=#{stamp},v1=#{digest}"
  end

  def post_hook(raw=body, signature: sign(raw))
    request.headers["Teller-Signature"] = signature if signature
    request.headers["CONTENT_TYPE"] = "application/json"
    post(:teller, body: raw)
  end

  before { allow(ENV).to receive(:[]).and_call_original }

  context "when the signing secret is configured" do
    before { allow(ENV).to receive(:[]).with("PORTFOLIO_TELLER_SIGN_SECRET").and_return(secret) }

    it "stores a correctly signed event as an ActionEvent" do
      expect { post_hook }.to change(ActionEvent, :count).by(1)
      expect(response).to have_http_status(:no_content)

      event = ActionEvent.last
      expect(event.user).to eq(User.me)
      expect(event.name).to eq("TellerWebhook")
      expect(event.notes).to eq("enrollment.disconnected")
      expect(event.timestamp).to eq(Time.utc(2026, 8, 10, 3, 49, 29))
      expect(event.data).to include(
        "teller"     => true,
        "type"       => "enrollment.disconnected",
        "webhook_id" => "wh_oiffb5cocakqmksbkg000",
      )
      expect(event.data["payload"]).to include("enrollment_id" => "enr_123")
    end

    it "does not file the event as a transaction" do
      post_hook
      expect(ActionEvent.last.name).not_to match(/transaction/i)
    end

    it "accepts a rotating secret's second signature" do
      stamp = Time.current.to_i
      good = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{stamp}.#{body}")
      header = "t=#{stamp},v1=#{"0" * 64},v1=#{good}"

      expect { post_hook(body, signature: header) }.to change(ActionEvent, :count).by(1)
    end

    it "rejects a signature computed with the wrong secret" do
      signature = sign(body, key: "wrong_secret")

      expect { post_hook(body, signature:) }.not_to change(ActionEvent, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a body that was altered after signing" do
      signature = sign(body)

      expect { post_hook(body.sub("enr_123", "enr_evil"), signature:) }
        .not_to change(ActionEvent, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a replayed event older than the tolerance" do
      signature = sign(body, at: 4.minutes.ago)

      expect { post_hook(body, signature:) }.not_to change(ActionEvent, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a request with no signature header" do
      expect { post_hook(body, signature: nil) }.not_to change(ActionEvent, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    # Malformed JSON never reaches the action — ApplicationController's
    # app-wide `rescue_bad_params` answers it at 422 first.
    it "records nothing on a signed but unparseable body" do
      raw = "not json"

      expect { post_hook(raw, signature: sign(raw)) }.not_to change(ActionEvent, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  context "when the signing secret is missing" do
    before { allow(ENV).to receive(:[]).with("PORTFOLIO_TELLER_SIGN_SECRET").and_return(nil) }

    it "refuses to record anything rather than trusting the request" do
      expect { post_hook }.not_to change(ActionEvent, :count)
      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
