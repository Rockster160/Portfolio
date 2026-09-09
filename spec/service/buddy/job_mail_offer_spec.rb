require "rails_helper"

RSpec.describe Buddy::JobMailOffer do
  let(:user) { create(:user) }
  let!(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }
  let(:metadata) {
    {
      kind:           :system,
      self_initiated: true,
      source:         :job_mail_watcher,
      sender:         "cordelia@icapital.com",
      subject:        "Zoom Interview Availability",
    }
  }
  let(:verdict) {
    {
      kind:     "interview request",
      company:  "iCapital, Inc.",
      headline: "Interview request for Full Stack Engineer",
    }
  }
  let(:arrived) { 2.hours.ago.change(usec: 0) }

  # The turn itself is not what's under test here — the fork and the seed are.
  before { allow(BuddyDeliverWorker).to receive(:perform_async) }

  def call(**overrides)
    described_class.call(
      user:        user,
      verdict:     verdict,
      card:        "📬 the card",
      metadata:    metadata,
      occurred_at: arrived, **overrides
    )
  end

  context "when the company is on the board" do
    let!(:job) { user.job_applications.create!(company: "iCapital", role: "Full Stack Engineer") }

    it "speaks an offer instead of posting the card" do
      message = call

      expect(message.body).to include("belongs to an application already on their board")
      expect(message.body).to include("Company: iCapital (Full Stack Engineer)")
      expect(message.body).not_to include("📬 the card")
      expect(message.metadata["job_application_id"]).to eq(job.id)
    end

    # A tracker that edits itself is worse than one that asks.
    it "tells her not to log it unless they ask" do
      expect(call.body).to include("Don't log it unless they ask")
    end

    # Without this the note lands on whenever they got round to answering.
    it "hands over the arrival time when there is no email to read it off" do
      body = call.body

      expect(body).to include("Arrived: #{arrived.iso8601}")
      expect(body).to include("add_job_note with occurred_at #{arrived.iso8601}")
    end

    # An email we hold answers the date itself, and buys a link back besides.
    it "prefers an email id when there is one" do
      email = user.emails.create!(
        mail_id: "m-#{SecureRandom.hex(4)}", timestamp: arrived, direction: :inbound,
        subject: "Zoom", blurb: "Availability?"
      )
      body = call(email: email).body

      expect(body).to include("Email id: #{email.id}")
      expect(body).to include("add_job_note with email_id #{email.id}")
      expect(body).not_to include("occurred_at")
    end
  end

  context "when nothing on the board matches" do
    # A recruiter's first contact is worth seeing and has nowhere to go.
    it "posts the card and offers nothing" do
      message = call

      expect(message.body).to eq("📬 the card")
      expect(message.body).not_to include("add_job_note")
    end

    it "does not match an application that is already over" do
      user.job_applications.create!(company: "iCapital", status: :rejected)

      expect(call.body).to eq("📬 the card")
    end
  end
end
