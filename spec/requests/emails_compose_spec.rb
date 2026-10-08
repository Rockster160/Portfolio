require "rails_helper"

# Composing and sending mail. The model was refactored around inbound/outbound
# mailbox columns and an S3 blob, but the compose path kept calling the sending
# API the refactor removed (`current_user.sent_emails`, `set_send_values`,
# `deliver!`), so every Reply, Forward and New Email raised a NoMethodError the
# moment the page loaded. This covers the rebuilt path end to end.
RSpec.describe "Email compose", type: :request do
  let(:user) { create(:user, role: :admin) }

  # An inbound message that reached a personal Gmail — the exact shape the prod
  # failure came from, where "our" address is NOT a registered domain and the
  # reply has to fall back to the house address.
  def inbound_from(sender_name:, sender_address:, our_address:, subject: "Next steps")
    raw = [
      "Date: Mon, 6 Oct 2026 16:45:57 -0600",
      "Subject: #{subject}",
      "From: #{sender_name} <#{sender_address}>",
      "To: #{our_address}",
      "Message-ID: <reply-#{SecureRandom.hex(4)}@example.com>",
      "MIME-Version: 1.0",
      "Content-Type: text/html; charset=UTF-8",
      "",
      "<p>Looking forward to it.</p>",
    ].join("\n")
    Emails::StoreRaw.call(user: user, raw: raw, direction: :inbound)
  end

  before do
    ActionMailer::Base.deliveries.clear
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  describe "GET /emails/new" do
    it "renders the compose form instead of raising" do
      get new_email_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Send")
    end

    it "prefills a reply with the sender as recipient, an RE: subject, and a registered From" do
      email = inbound_from(
        sender_name:    "Neighbor Scheduler",
        sender_address: "scheduler@neighbor.com",
        our_address:    "rocco11nicholls@gmail.com",
        subject:        "Next steps with Neighbor!",
      )

      get new_email_path(email: email.reply_defaults)

      expect(response).to have_http_status(:ok)
      # The sender becomes the To; the Gmail box we received on is not a domain
      # we can send from, so From falls back to the house address.
      expect(response.body).to include("scheduler@neighbor.com")
      expect(response.body).to include('value="RE: Next steps with Neighbor!"')
      expect(response.body).to include('value="contact"')
    end
  end

  describe "POST /emails" do
    let(:valid_params) {
      {
        email: {
          from_user:   "rocco",
          from_domain: "ardesian.com",
          to:          "boss@example.com, team@example.com",
          subject:     "Status update",
          html_body:   "<p>All shipped.</p>",
        },
      }
    }

    it "sends the mail and files an outbound copy" do
      expect { post emails_path, params: valid_params }
        .to change { user.emails.outbound.count }.by(1)

      expect(response).to redirect_to(emails_path)

      delivery = ActionMailer::Base.deliveries.last
      expect(delivery.from).to eq(["rocco@ardesian.com"])
      expect(delivery.to).to contain_exactly("boss@example.com", "team@example.com")
      expect(delivery.subject).to eq("Status update")
      expect(delivery.body.to_s).to include("All shipped.")

      sent = user.emails.outbound.order(:created_at).last
      expect(sent.from_display).to include("rocco@ardesian.com")
      expect(sent.to_display).to include("boss@example.com").and include("team@example.com")
    end

    it "carries an attached file into the sent message" do
      file = Rack::Test::UploadedFile.new(
        StringIO.new("%PDF-1.4 offer letter"), "application/pdf", original_filename: "offer.pdf"
      )
      params = valid_params.deep_merge(email: { tempfiles: [file] })

      post emails_path, params: params

      expect(response).to redirect_to(emails_path)
      delivery = ActionMailer::Base.deliveries.last
      expect(delivery.attachments.map(&:filename)).to include("offer.pdf")
      expect(delivery.attachments.first.read).to eq("%PDF-1.4 offer letter")
    end

    it "refuses a domain we do not control, sending nothing" do
      params = valid_params.deep_merge(email: { from_domain: "gmail.com" })

      expect { post emails_path, params: params }.not_to(change(::Email, :count))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(response.body).to include("registered domain")
    end

    it "refuses a draft with no valid recipient, sending nothing" do
      params = valid_params.deep_merge(email: { to: "not-an-address" })

      expect { post emails_path, params: params }.not_to(change(::Email, :count))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
