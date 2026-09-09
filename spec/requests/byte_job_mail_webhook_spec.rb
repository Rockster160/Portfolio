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
    expect(body).to include("--- the message ---")
    expect(body).to include("We'd like to schedule a Zoom.")
    expect(body).to include("keep the message itself as the note")
  end

  # A recruiter's first contact is worth seeing and has nothing to attach to.
  it "posts the watcher's own card when nothing matches" do
    post_mail

    expect(response).to have_http_status(:created)
    expect(user.byte_messages.order(:id).last.body).to eq("📬 Interview confirmed")
  end

  it "keeps the metadata the watcher sent, and the kind the client renders on" do
    post_mail

    metadata = user.byte_messages.order(:id).last.metadata
    expect(metadata["source"]).to eq("job_mail_watcher")
    expect(metadata["kind"]).to eq("system")
    expect(metadata["subject"]).to eq("Zoom Interview Confirmation")
  end

  it "rejects a body with no card to fall back on" do
    post_mail(card: "")

    expect(response).to have_http_status(:bad_request)
  end
end
