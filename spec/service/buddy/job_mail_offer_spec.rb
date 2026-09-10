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

    # add_job_note is level 3: calling it puts an UNCHECKED card on screen that
    # writes nothing until it's tapped. The card IS the question, so asking in
    # prose first is a round trip for something already reviewable.
    it "tells her to make the card rather than ask for permission" do
      body = call.body

      expect(body).to include("CALL add_job_note")
      expect(body).to include("do not offer to, do not ask")
    end

    # The seed is INSTRUCTIONS. Carrying the card's `kind: :system` printed the
    # whole thing — framing, instructions and the entire email — into the
    # thread as a message addressed to them.
    it "stays out of the thread" do
      message = call

      expect(message.metadata["hidden"]).to be(true)
      expect(message.metadata["kind"]).to eq("buddy_trigger")
    end

    it "hands over the row's own link" do
      expect(call.body).to include("/interviews/#{job.id}")
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

  # The board was built by hand by pasting the mail in and setting a status.
  # Buddy can only continue that if the mail itself reaches her.
  context "when the message body came with it" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }
    let(:mail_body) { "Hi Rocco,\n\nWe'd like to schedule a 30-minute Zoom.\n\nCordelia" }

    it "quotes the message, fenced so its end is unambiguous" do
      body = call(body: mail_body).body

      expect(body).to include("--- the message, for the NOTE only ---")
      expect(body).to include("We'd like to schedule a 30-minute Zoom.")
      expect(body).to include("--- end ---")
    end

    it "spells out the trimming habit and asks for a real tag" do
      body = call(body: mail_body).body

      expect(body).to include("keep the message itself as the note")
      expect(body).to include("quoted thread")
      expect(body).to include("Pick the `tag` that matches")
    end

    # They read the card, not the mail. Pasting it into the spoken line puts the
    # thing they asked to be spared right back in front of them.
    it "keeps the message out of what she says" do
      body = call(body: mail_body).body

      expect(body).to include("do not paste any of it into your reply")
      expect(body).to include("belongs in the note only")
    end

    # Reading the body off disk is a soft failure upstream. An offer made from
    # the headline alone must not promise a message it hasn't got.
    it "promises nothing about a message it never received" do
      body = call.body

      expect(body).not_to include("--- the message")
      expect(body).not_to include("keep the message itself")
      expect(body).to include("Pick the `tag` that matches")
    end
  end

  # He rarely writes, so almost anything he sends that isn't ordinary life is
  # part of the search — and his side of a thread is half of what the board's
  # timeline is made of.
  context "when it is mail he sent" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }

    def sent(**overrides)
      described_class.call(
        user: user, verdict: verdict, card: "📤 the card", metadata: metadata,
        occurred_at: arrived, outgoing: true, **overrides
      )
    end

    it "reads as his own message, not as post arriving" do
      body = sent.body

      expect(body).to include("They just SENT this")
      expect(body).to include("Sent: #{arrived.iso8601}")
      expect(body).to include("To: #{metadata[:sender]}")
    end

    # `responded` is the other half of `heard_back`, and the whole question a
    # timeline answers is whose court the ball is in.
    it "points at the responded tag without forcing it" do
      body = sent.body

      expect(body).to include("`responded` is usually the tag")
      expect(body).to include("unless they withdrew")
    end

    it "doesn't explain his own words back to him" do
      expect(sent.body).to include("they wrote it, so don't explain it back")
    end
  end

  context "when nothing on the board matches" do
    # A company with no row is a suggestion to START one, not a dead end. This
    # is a recruiter's first approach, or an application made without saying so.
    it "proposes tracking the company instead of just showing a card" do
      body = call.body

      expect(body).to include("NOT on their board yet")
      expect(body).to include("CALL add_job_application")
      expect(body).to include("do not offer to, do not ask")
    end

    it "carries the mail's own arrival time onto the new row" do
      expect(call.body).to include("occurred_at #{arrived.iso8601}")
    end

    # Nothing to propose: any row would be invented. The card is still worth
    # seeing, which is the whole reason a plain card still exists.
    it "falls back to the card when the classifier named no company" do
      message = described_class.call(
        user: user, verdict: verdict.merge(company: nil), card: "📬 the card",
        metadata: metadata, occurred_at: arrived
      )

      expect(message.body).to eq("📬 the card")
      expect(message.body).not_to include("add_job_application")
    end
  end

  # It used to refuse a settled one, and post a bare card with nowhere for the
  # message to go. But the last word from a company is usually the rejection,
  # and it arriving is the beat that closes the row - see prod 5759, where
  # hiding closed applications from the model is what let it settle the wrong
  # one. `status` is on the row either way, so a settled match reads as settled.
  context "when the matching application is already settled" do
    let!(:job) { user.job_applications.create!(company: "iCapital", status: :rejected) }

    it "still offers, against the row it belongs to" do
      message = call

      expect(message.body).to include("belongs to an application already on their board")
      expect(message.metadata["job_application_id"]).to eq(job.id)
    end
  end
end
