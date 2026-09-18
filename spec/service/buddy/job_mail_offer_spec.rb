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
    # Prod 6395, Aledade: a rejection's headline names no role, and the seed
    # called the job it was about "a different role" because only the headline
    # was checked.
    it "matches the role off the subject when the headline names none" do
      verdict[:headline] = "iCapital is moving forward with other candidates"
      metadata[:subject] = "Your application for Full Stack Engineer"

      body = call.body

      expect(body).to include("belongs to an application already on their board")
      expect(body).not_to include("different role")
    end

    # Rocco, 18 Sep: "can we enforce that it adds the email as a note to the
    # company/interview record in one form or another?" Nothing enforced it -
    # the model had to call, and then the card had to be tapped, and either half
    # failing lost the beat with no trace. Prod 6551 called nothing; notes 85
    # and 86 sat unticked for seven hours.
    describe "filing the mail on the row" do
      let(:email) {
        user.emails.create!(
          direction: :inbound,
          mail_id:   "m-1",
          subject:   metadata[:subject],
          blurb:     "Thanks for applying to iCapital.",
          timestamp: arrived,
        )
      }

      it "writes the mail onto the row before any model sees it" do
        call(email: email, body: "Thanks for applying to iCapital.")

        note = job.notes.last
        expect(note.body).to eq("Thanks for applying to iCapital.")
        expect(note.occurred_at).to eq(arrived)
        expect(note.source).to eq("Email")
        expect(note.url).to be_present
      end

      # Nothing in Ruby can tell a receipt from a rejection, so nothing in Ruby
      # picks a tag. `note` settles no application.
      it "leaves it untagged and the application alone" do
        call(email: email, body: "We're moving forward with other candidates.")

        expect(job.notes.last.tag).to eq("note")
        expect(job.reload.status).to eq("active")
      end

      it "stamps the email so the same mail is never filed twice" do
        call(email: email, body: "Thanks for applying to iCapital.")
        first = email.reload.job_triage[:job_note_id]

        expect { call(email: email, body: "Thanks for applying to iCapital.") }
          .not_to(change { job.notes.count })
        expect(email.reload.job_triage[:job_note_id]).to eq(first)
      end

      it "still asks for the tag, and keeps the filing out of the reply" do
        body = call(email: email, body: "Thanks for applying to iCapital.").body

        expect(body).to include("already filed on that row as a plain note")
        expect(body).to include("do not mention it")
        expect(body).to include("CALL add_job_note")
      end

      # The one case where the ROW itself might be wrong. Filing it anyway would
      # put the receipt on a sibling application, which is the failure the
      # question below exists to avoid.
      it "files nothing when the mail may be about a different role" do
        user.job_applications.create!(company: "iCapital", role: "Backend Engineer")
        verdict[:headline] = "Application confirmation for iCapital"
        metadata[:subject] = "Thank you for applying"

        expect { call(email: email, body: "Thanks!") }.not_to change(JobNote, :count)
      end

      it "files nothing when there is no mail to file" do
        expect { call }.not_to change(JobNote, :count)
      end
    end

    # Prod 6501, Aura Frames, 17 Sep - the third of these, and the first after a
    # fix aimed squarely at it. Neither the subject ("Thank you for applying to
    # Aura") nor the headline ("Application confirmation for Aura Frames") names
    # a role at all, so `role_named_in?` says false the same way it says false
    # for a mail about a genuinely different job - and the seed then stated that
    # as fact and ordered a second application off the back of it.
    describe "when the mail names no role at all" do
      before {
        verdict[:headline] = "Application confirmation for iCapital"
        metadata[:subject] = "Thank you for applying to iCapital"
      }

      it "does not call it a different role" do
        expect(call.body).not_to include("different role than")
      end

      it "says it cannot tell, and leaves both doors open" do
        body = call.body

        expect(body).to include("nothing in this mail says")
        expect(body).to include("add the note to the row below")
        expect(body).to include("add_job_application")
      end
    end

    # Prod 6502: the seed that marked a chore for Chelsea instead of logging the
    # beat it was sent for.
    it "names the only two tools the turn is for" do
      expect(call.metadata["seed_tools"]).to eq(%w[add_job_note add_job_application])
    end

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

  # One company, several jobs. A role-aware resolver answers nil when the mail
  # does not say which — and nil used to mean "not on the board", which here
  # would propose opening a company that is already on it twice.
  context "when the company is on the board more than once" do
    let!(:backend) { user.job_applications.create!(company: "iCapital", role: "Senior Backend Engineer") }
    let!(:manager) { user.job_applications.create!(company: "iCapital", role: "Engineering Manager") }

    it "asks which job rather than proposing a new company" do
      body = call.body

      expect(body).to include("on their board 2 times")
      expect(body).to include("Senior Backend Engineer")
      expect(body).to include("Engineering Manager")
      expect(body).to include("with `role` naming WHICH")
      expect(body).not_to include("CALL add_job_application")
    end

    it "still keeps the mail's own words for the note" do
      body = call(body: "Hi Rocco,\n\nWe'd like to schedule a Zoom.").body

      expect(body).to include("--- the message, for the NOTE only ---")
      expect(body).to include("VERBATIM")
    end

    # The mail naming one of them is the ordinary case, and it must go straight
    # through to that row rather than asking.
    it "goes straight to the row the mail names" do
      message = call(verdict: verdict.merge(headline: "Senior Backend Engineer interview request"))

      expect(message.body).to include("belongs to an application already on their board")
      expect(message.metadata["job_application_id"]).to eq(backend.id)
    end
  end

  # Prod 6162, 14 Sep. A GitLab confirmation off the DOMAIN inbox was logged as
  # "Greenhouse confirmed receipt of your application" — the seed's own headline
  # read back. The watcher hands the words over because it read them off disk;
  # this side never did, so the seed carried no message at all and the trimming
  # habit was never even said. The mail was on S3 the whole time.
  context "when only the email came with it" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }
    let(:email) {
      user.emails.create!(
        mail_id: "m-#{SecureRandom.hex(4)}", timestamp: arrived, direction: :inbound,
        subject: "Zoom", blurb: "Availability?"
      )
    }

    it "reads the mail's own words off it" do
      allow_any_instance_of(Email).to receive(:text_body)
        .and_return("Hi Rocco,\n\n\n\nWe'd like to schedule a Zoom.  \n\nCordelia\n")

      body = call(email: email).body

      expect(body).to include("--- the message, for the NOTE only ---")
      expect(body).to include("We'd like to schedule a Zoom.")
      expect(body).to include("VERBATIM")
      # Trimmed the way the watcher trims what it reads, so a seed looks the
      # same whichever inbox it came from.
      expect(body).not_to include("Zoom.  \n")
      expect(body).not_to include("\n\n\n")
    end

    # What the watcher sends wins: it read the message off disk before Mail.app
    # had finished with it, and it is the one that knows about a sent copy.
    it "leaves a body it was handed alone" do
      allow_any_instance_of(Email).to receive(:text_body).and_return("off the blob")

      body = call(email: email, body: "what the watcher read").body

      expect(body).to include("what the watcher read")
      expect(body).not_to include("off the blob")
    end

    # The blob lives on S3. A beat announced without its message is worth far
    # more than one not announced at all.
    it "still speaks the offer when the copy cannot be read" do
      allow(Rails.logger).to receive(:warn)
      allow_any_instance_of(Email).to receive(:text_body).and_raise("no such key")

      body = call(email: email).body

      expect(body).to include("CALL add_job_note")
      expect(body).not_to include("--- the message")
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

    # Prod 5934 proposed a one-sentence precis of a rejection instead of the
    # rejection. "pass the part that carries the substance" was read as an
    # invitation to summarise, and the words are the whole point of keeping it.
    it "asks for the words themselves, not a precis of them" do
      body = call(body: mail_body).body

      expect(body).to include("VERBATIM")
      expect(body).to include("do not summarise it")
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
