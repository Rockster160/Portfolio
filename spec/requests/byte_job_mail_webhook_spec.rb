require "rails_helper"

# The Mac watcher reads the personal Gmail, where the replies from actual people
# arrive. It hands over its VERDICT rather than a finished message, because
# whether the company is already on the interview board is the one thing that
# side cannot know.
RSpec.describe "POST /webhooks/byte/job_mail", type: :request do
  let!(:user) { create(:user) }
  let!(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:arrived) { 2.hours.ago.change(usec: 0) }

  let(:payload) {
    {
      user_id:     user.id,
      card:        "📬 Interview confirmed",
      company:     "iCapital, Inc.",
      kind:        "interview confirmation",
      headline:    "Interview confirmed for Sep 24",
      occurred_at: arrived.iso8601,
      metadata:    { sender: "cordelia@icapital.com", subject: "Zoom Interview Confirmation" }.to_json,
    }
  }

  before do
    allow(BuddyDeliverWorker).to receive(:perform_async)
    allow(ByteLocal).to receive(:valid_secret?).and_return(true)
  end

  def post_mail(**overrides)
    post "/webhooks/byte/job_mail", params: payload.merge(overrides)
  end

  it "refuses without the shared secret" do
    allow(ByteLocal).to receive(:valid_secret?).and_return(false)

    post_mail

    expect(response).to have_http_status(:unauthorized)
    expect(user.byte_messages.count).to be_zero
  end

  context "when the company is on the board" do
    let!(:job) { user.job_applications.create!(company: "iCapital", role: "Full Stack Engineer") }

    it "speaks an offer carrying the mail's own arrival time" do
      post_mail

      expect(response).to have_http_status(:created)
      message = user.byte_messages.order(:id).last
      expect(message.body).to include("iCapital")
      # In THEIR wall clock, which is the form the tool's :iso_time args are
      # documented to take — the controller wraps the request in their zone.
      local = arrived.in_time_zone(user.timezone).iso8601
      expect(message.body).to include("add_job_note with occurred_at #{local}")
      expect(message.body).not_to include("📬 Interview confirmed")
      expect(message.metadata["job_application_id"]).to eq(job.id)
    end
  end

  it "carries the message body the watcher read off disk" do
    user.job_applications.create!(company: "iCapital")

    post_mail(body: "Hi Rocco,\n\nWe'd like to schedule a Zoom.\n\nCordelia")

    body = user.byte_messages.order(:id).last.body
    expect(body).to include("--- the message, for the NOTE only ---")
    expect(body).to include("We'd like to schedule a Zoom.")
    expect(body).to include("keep the message itself as the note")
  end

  # A recruiter's first contact has no row yet — so the suggestion is to make
  # one, not to show a card and stop.
  it "proposes tracking the company when nothing matches" do
    post_mail

    expect(response).to have_http_status(:created)
    body = user.byte_messages.order(:id).last.body
    expect(body).to include("CALL add_job_application")
  end

  it "falls back to the card when no company was named" do
    post_mail(company: "")

    expect(user.byte_messages.order(:id).last.body).to eq("📬 Interview confirmed")
  end

  it "keeps the metadata the watcher sent, and the kind the client renders on" do
    post_mail(company: "")

    metadata = user.byte_messages.order(:id).last.metadata
    expect(metadata["source"]).to eq("job_mail_watcher")
    expect(metadata["kind"]).to eq("system")
    expect(metadata["subject"]).to eq("Zoom Interview Confirmation")
  end

  # The mail itself, kept the way domain mail is. Until this existed, a beat
  # logged off Gmail had no date but the one it was told, no sender, and nothing
  # to link back to — strictly poorer than the same beat logged off ardesian.
  describe "the mail itself" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }
    let(:raw) {
      [
        "From: Cordelia Vance <cordelia@icapital.com>",
        "To: Rocco Nicholls <rocco@example.com>",
        "Subject: Zoom Interview Confirmation",
        "Message-ID: <zoom-1@icapital.com>",
        "Date: #{arrived.rfc2822}",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "Hi Rocco,\n\nWe'd like to schedule a Zoom.\n\nCordelia\n",
      ].join("\n")
    }

    it "keeps a row with the mail on it and hands the seed its number" do
      post_mail(raw_b64: Base64.encode64(raw))

      email = user.emails.order(:id).last
      expect(email.mail_id).to eq("zoom-1@icapital.com")
      expect(email.mail_blob).to be_attached
      expect(user.byte_messages.order(:id).last.body).to include("Email id: #{email.id}")
    end

    it "offers the mail as something to link" do
      post_mail(raw_b64: Base64.encode64(raw))

      email = user.emails.order(:id).last
      expect(user.byte_messages.order(:id).last.body).to include("/emails/#{email.id}")
    end

    it "files one they sent as outbound" do
      post_mail(raw_b64: Base64.encode64(raw), outgoing: "1")

      expect(user.emails.order(:id).last).to be_outbound
    end

    # The watcher already decided this one on the Mac. Stamping the verdict is
    # what stops the app triaging it a second time and what puts it in front of
    # the job_search context section.
    it "stamps the watcher's verdict rather than re-deciding it" do
      post_mail(raw_b64: Base64.encode64(raw))

      expect(Email.job_mail).to include(user.emails.order(:id).last)
      expect(user.emails.order(:id).last.job_triage[:company]).to eq("iCapital, Inc.")
    end

    # Mail announced without its paperwork is worth far more than mail not
    # announced, so no raw copy simply means no row.
    it "still speaks the offer when no raw copy came with it" do
      post_mail

      expect(user.emails.count).to be_zero
      expect(user.byte_messages.order(:id).last.body).to include("CALL add_job_note")
    end
  end

  it "rejects a body with no card to fall back on" do
    post_mail(card: "")

    expect(response).to have_http_status(:bad_request)
  end
end
