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

    it "seeds a hidden turn about the row instead of posting the card", :aggregate_failures do
      message = call

      expect(message.body).to include("Company: iCapital (Full Stack Engineer)")
      expect(message.body).to include("/interviews/#{job.id}")
      # With no email to read it off, the arrival time is handed over.
      expect(message.body).to include("occurred_at #{arrived.iso8601}")
      expect(message.body).not_to include("📬 the card")
      expect(message.metadata).to include(
        "job_application_id" => job.id,
        "hidden"             => true,
        "kind"               => "buddy_trigger",
        "seed_tools"         => %w[add_job_note add_job_application],
      )
    end

    # A rejection's headline often names no role; the subject still can.
    it "matches the role off the subject when the headline names none" do
      verdict[:headline] = "iCapital is moving forward with other candidates"
      metadata[:subject] = "Your application for Full Stack Engineer"

      expect(call.body).not_to include("different role")
    end

    # An email we hold answers the date itself, and buys a link back besides.
    it "prefers an email id over the arrival time when there is one", :aggregate_failures do
      email = user.emails.create!(
        mail_id: "m-#{SecureRandom.hex(4)}", timestamp: arrived, direction: :inbound,
        subject: "Zoom", blurb: "Availability?"
      )
      body = call(email: email).body

      expect(body).to include("email_id #{email.id}")
      expect(body).not_to include("occurred_at")
    end

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

      # A booking whose words are a reschedule link and a LinkedIn URL carries
      # its slot only in the calendar part.
      describe "a calendar invite inside it" do
        let(:invite) {
          {
            starts_at: Time.utc(2026, 10, 27, 17, 30),
            ends_at:   Time.utc(2026, 10, 27, 18, 0),
            location:  "+1 385-259-9640",
            cancelled: false,
          }
        }

        it "states the slot in their own zone, with the offset to book it at" do
          allow(email).to receive(:calendar_invite).and_return(invite)

          body = travel_to(Time.utc(2026, 10, 20)) { call(email: email, body: "Need to make changes to this event?").body }

          expect(body).to include("Tuesday Oct 27, 11:30am MDT (2026-10-27T11:30:00-06:00)", "30 minutes", "+1 385-259-9640")
        end

        # A cancellation lands after the slot it calls off, on the same day.
        it "says when the invite calls the booking off, naming the day from now" do
          allow(email).to receive(:calendar_invite).and_return(invite.merge(cancelled: true))

          body = travel_to(Time.utc(2026, 10, 27, 21, 25)) { call(email: email, body: "Cancelled").body }

          expect(body).to include("CANCELLATION of the booking at: today, Tuesday Oct 27, 11:30am MDT")
        end

        it "says nothing of an invite the mail doesn't have" do
          allow(email).to receive(:calendar_invite).and_return(nil)

          expect(call(email: email, body: "Thanks").body).not_to include("Calendar")
        end
      end

      describe "a reminder" do
        before { metadata[:subject] = "Reminder: iCapital Onboarding: Welcome Aboard!" }

        it "is filed as a reminder, with no turn and nothing said", :aggregate_failures do
          expect(Buddy::CompanionDelivery).not_to receive(:deliver_prompt)
          expect(Buddy::CompanionDelivery).not_to receive(:deliver_plain)

          filed = call(email: email, body: "Please sign the documents.")

          expect(filed).to be_a(JobNote)
          expect(filed).to have_attributes(tag: "reminder", job_application_id: job.id)
          expect(email.reload.job_triage[:job_note_id]).to eq(filed.id)
        end

        # A person writing back is not a machine nudging.
        it "reads any subject that says it is one, but not a reply to one", :aggregate_failures do
          ["Reminder - Background Check Needed", "Friendly reminder: your interview", "[iCapital] Reminder: sign"].each { |subject|
            expect(described_class.reminder_mail?(subject: subject)).to be(true), subject
          }
          expect(described_class.reminder_mail?(subject: "Re: Reminder: iCapital Onboarding")).to be(false)
          expect(described_class.reminder_mail?(subject: "Your offer reminders")).to be(false)
        end
      end

      # Nothing in Ruby can tell a receipt from a rejection, so nothing in Ruby
      # picks a tag, and `note` settles no application.
      it "writes the mail onto the row untagged before any model sees it, once", :aggregate_failures do
        call(email: email, body: "We're moving forward with other candidates.")

        note = job.notes.last
        expect(note.body).to eq("We're moving forward with other candidates.")
        expect(note.tag).to eq("note")
        expect(note.occurred_at).to eq(arrived)
        expect(note.source).to eq("Email")
        expect(note.url).to be_present
        expect(job.reload.status).to eq("active")
        expect(email.reload.job_triage[:job_note_id]).to eq(note.id)

        expect { call(email: email, body: "We're moving forward with other candidates.") }
          .not_to(change { job.notes.count })
        expect(email.reload.job_triage[:job_note_id]).to eq(note.id)
      end

      # The row is a guess, so it is STAMPED as one - that is what lets `role`
      # move the beat rather than file a second copy of it.
      it "files it as a guess when the company holds several rows and the mail names none" do
        user.job_applications.create!(company: "iCapital", role: "Backend Engineer")
        verdict[:headline] = "Application confirmation for iCapital"
        metadata[:subject] = "Thank you for applying"

        expect { call(email: email, body: "Thanks!") }.to change(JobNote, :count).by(1)
        expect(email.reload.job_triage[:job_note_guess]).to be(true)
      end

      # One row for the company means there is no sibling for it to belong to.
      it "files a mail that names no role when the company holds ONE row", :aggregate_failures do
        verdict[:headline] = "Interview with iCapital"
        metadata[:subject] = "Please provide your interview availability"

        call(email: email, body: "We're still waiting on your availability.")

        expect(job.notes.last.body).to eq("We're still waiting on your availability.")
        expect(email.reload.job_triage[:job_note_id]).to eq(job.notes.last.id)
      end

      it "files nothing when there is no mail to file" do
        expect { call }.not_to change(JobNote, :count)
      end
    end

    # `role_named_in?` returns false for a mail naming no role at all exactly
    # as it does for one naming a different role.
    it "does not call a mail that names no role a different role" do
      verdict[:headline] = "Application confirmation for iCapital"
      metadata[:subject] = "Thank you for applying to iCapital"

      expect(call.body).not_to include("different role than")
    end

    # Reaching this branch MEANS one row: resolve_application hands a row back
    # without consulting the role only when the company holds exactly one.
    describe "when the mail's title for the job differs from the board's" do
      let!(:job) {
        user.job_applications.create!(company: "EasyLlama", role: "Founding Platform Engineer -- Ruby on Rails")
      }

      before {
        verdict[:company]  = "EasyLlama"
        verdict[:headline] = "Application for Staff Software Engineer, Platform role rejected"
        metadata[:subject] = "EasyLlama Application Update"
      }

      it "seeds against the one row rather than ordering a second application", :aggregate_failures do
        message = call

        expect(message.metadata["job_application_id"]).to eq(job.id)
        expect(message.body).not_to include("that is a SEPARATE application")
      end
    end
  end

  # A role-aware resolver answers nil when the mail does not say which, and that
  # must not read as "not on the board".
  context "when the company is on the board more than once" do
    let!(:backend) { user.job_applications.create!(company: "iCapital", role: "Senior Backend Engineer") }
    let!(:manager) { user.job_applications.create!(company: "iCapital", role: "Engineering Manager") }

    it "names every row rather than proposing a new company, and expects a call", :aggregate_failures do
      message = call

      expect(message.body).to include("Senior Backend Engineer", "Engineering Manager")
      expect(message.body).not_to include("CALL add_job_application")
      expect(message.metadata["seed_call"]).to eq("add_job_note")
      expect(message.metadata["seed_tools"]).to eq(%w[add_job_note add_job_application])
    end

    it "carries the row something happened on most recently" do
      backend.notes.create!(tag: :heard_back, occurred_at: 1.day.ago)
      manager.notes.create!(tag: :heard_back, occurred_at: 9.days.ago)

      expect(call.metadata["job_application_id"]).to eq(backend.id)
    end

    it "goes straight to the row the mail names" do
      message = call(verdict: verdict.merge(headline: "Senior Backend Engineer interview request"))

      expect(message.metadata["job_application_id"]).to eq(backend.id)
    end

    # The mail goes onto the likeliest row and `role` moves it, so the worst
    # case is a beat on the wrong job of the right company.
    describe "filing it on a guess" do
      let(:email) {
        user.emails.create!(direction: :inbound, mail_id: "m-amb", subject: "Zoom Interview Availability",
          blurb: "Zoom", timestamp: arrived)
      }

      it "files on the most recently active row, stamped as a guess and marked in the seed", :aggregate_failures do
        backend.notes.create!(tag: :heard_back, occurred_at: 5.days.ago)
        manager.notes.create!(tag: :heard_back, occurred_at: 1.day.ago)

        body = call(email: email, body: "Hi Rocco,\n\nWe'd like to schedule a Zoom.").body

        expect(manager.notes.reload.map(&:body)).to include(/schedule a Zoom/)
        expect(backend.notes.reload.count).to eq(1)
        expect(email.reload.job_triage[:job_note_guess]).to be(true)
        expect(email.job_triage[:job_note_id]).to eq(user.job_notes.last.id)
        expect(body).to include("<- filed here")
      end

      it "leaves a settled row alone even when it moved more recently" do
        backend.notes.create!(tag: :heard_back, occurred_at: 5.days.ago)
        manager.notes.create!(tag: :rejected, occurred_at: 1.day.ago)

        call(email: email, body: "Hi Rocco,\n\nWe'd like to schedule a Zoom.")

        expect(backend.notes.reload.map(&:body)).to include(/schedule a Zoom/)
      end
    end
  end

  context "when only the email came with it" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }
    let(:email) {
      user.emails.create!(
        mail_id: "m-#{SecureRandom.hex(4)}", timestamp: arrived, direction: :inbound,
        subject: "Zoom", blurb: "Availability?"
      )
    }

    # Trimmed the way the watcher trims what it reads, so a seed looks the same
    # whichever inbox it came from.
    it "reads the mail's own words off it, trimmed", :aggregate_failures do
      allow_any_instance_of(Email).to receive(:text_body)
        .and_return("Hi Rocco,\n\n\n\nWe'd like to schedule a Zoom.  \n\nCordelia\n")

      body = call(email: email).body

      expect(body).to include("We'd like to schedule a Zoom.")
      expect(body).not_to include("Zoom.  \n")
      expect(body).not_to include("\n\n\n")
    end

    # The watcher read the message off disk and knows about a sent copy.
    it "leaves a body it was handed alone" do
      allow_any_instance_of(Email).to receive(:text_body).and_return("off the blob")

      body = call(email: email, body: "what the watcher read").body

      expect(body).to include("what the watcher read")
      expect(body).not_to include("off the blob")
    end

    # A beat announced without its message is worth far more than none at all.
    it "still seeds the offer when the copy cannot be read" do
      allow(Rails.logger).to receive(:warn)
      allow_any_instance_of(Email).to receive(:text_body).and_raise("no such key")

      message = call(email: email)

      expect(message.metadata["job_application_id"]).to eq(job.id)
      expect(message.body).not_to include("--- the message")
    end
  end

  context "when the message body came with it" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }

    it "quotes the message, fenced so its end is unambiguous, and promises none without one", :aggregate_failures do
      body = call(body: "Hi Rocco,\n\nWe'd like to schedule a 30-minute Zoom.\n\nCordelia").body

      expect(body).to include("--- the message, for the NOTE only ---")
      expect(body).to include("We'd like to schedule a 30-minute Zoom.")
      expect(body).to include("--- end ---")

      expect(call.body).not_to include("--- the message")
    end
  end

  context "when it is mail he sent" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }

    it "seeds his own message with when it went and to whom", :aggregate_failures do
      body = described_class.call(
        user: user, verdict: verdict, card: "📤 the card", metadata: metadata,
        occurred_at: arrived, outgoing: true
      ).body

      expect(body).to include("Sent: #{arrived.iso8601}")
      expect(body).to include("To: #{metadata[:sender]}")
      # The company is the RECIPIENT, so the sender can't be misread.
      expect(body).to include("SENT this TO iCapital")
    end
  end

  # Usually a recruiter's first approach, with no row to attach it to and so
  # nothing to offer. All it posts is the card.
  context "when the mail names no company at all" do
    let(:verdict) { { kind: "recruiter outreach", company: nil, headline: "Backend Engineer" } }
    let(:email) {
      user.emails.create!(
        direction: :inbound,
        mail_id:   "m-inmail",
        subject:   "Backend Engineer",
        blurb:     "Backend Engineer",
        timestamp: arrived,
      )
    }

    it "posts the card with a link to the mail and its first line that says something", :aggregate_failures do
      message = call(email: email, body: "Hi Rocco,\n\nI am hiring for a Ruby team in Denver.")

      expect(message.body).to include("📬 the card")
      expect(message.body).to include("/emails/#{email.id}")
      expect(message.body).to include("> I am hiring for a Ruby team in Denver.")
      expect(message.body).not_to include("> Hi Rocco,")
      expect(message.body).not_to include("add_job_application")
    end

    it "posts the card alone when there is no mail on file" do
      expect(call(email: nil, body: nil).body).to eq("📬 the card")
    end
  end

  context "when nothing on the board matches" do
    it "proposes tracking the company, carrying the mail's arrival time onto the new row", :aggregate_failures do
      body = call.body

      expect(body).to include("CALL add_job_application")
      expect(body).to include("occurred_at #{arrived.iso8601}")
    end
  end

  # A background check names the PAST employers it is verifying and never the
  # one that ordered it. The vendor written on the row is the only thing in that
  # mail pointing back at the process it belongs to.
  context "when the company named is not on the board but the sender is written down" do
    let!(:job) {
      user.job_applications.create!(
        company: "iCapital", role: "Full Stack Engineer", status: :offer,
        known_as: ["accurate.com"]
      )
    }
    let(:email) {
      user.emails.create!(
        mail_id: "m-#{SecureRandom.hex(4)}", timestamp: arrived, direction: :inbound,
        subject: "Other Information Needed for Screening Request", blurb: "Employer: Orca Health",
        outbound_mailboxes: [{ name: "Accurate CS", address: "infoneeded@accurate.com" }]
      )
    }

    before {
      verdict[:company]  = "Orca Health"
      verdict[:headline] = "Asked for contact details to finish the screening"
      metadata[:sender]  = "infoneeded@accurate.com"
    }

    it "files the mail on the row that uses that vendor, not a new one for the employer", :aggregate_failures do
      message = call(email: email, body: "Employer: Orca Health")

      expect(message.metadata["job_application_id"]).to eq(job.id)
      expect(job.notes.reload.size).to eq(1)
      expect(message.body).to include("Company: iCapital")
      expect(message.body).not_to include("Company: Orca Health")
      expect(message.body).not_to include("CALL add_job_application")
    end

    it "leaves a sender nobody wrote down to the ordinary matching" do
      job.update!(known_as: [])

      expect(call(email: email, body: "Employer: Orca Health").body).to include("CALL add_job_application")
    end
  end

  # A named company is not the same as a real one: a job board's name on an
  # ATS receipt, for instance.
  context "when the company named is not on the board but the role is" do
    let!(:job) {
      user.job_applications.create!(company: "Peregrine Advisors", role: "Generative AI Engineer")
    }

    before {
      verdict[:company]  = "OpenDataJobs"
      verdict[:headline] = "Application received for Generative AI Engineer"
      metadata[:subject] = "Thank you for applying"
    }

    it "files the mail on the row whose role it names" do
      message = call

      expect(message.metadata["job_application_id"]).to eq(job.id)
      expect(message.body).not_to include("CALL add_job_application")
    end

    # Two rows answering to the role is a coin toss, and the company name -
    # wrong or not - is the better thing to go on.
    it "proposes the company when two rows answer to the role, or none does", :aggregate_failures do
      user.job_applications.create!(company: "Globex", role: "Generative AI Engineer")
      body = call.body
      expect(body).to include("CALL add_job_application")
      expect(body).to include("Company: OpenDataJobs")

      verdict[:headline] = "Application received for Staff Platform Engineer"
      expect(call.body).to include("CALL add_job_application")
    end
  end

  # The last word from a company is usually the rejection, and it arriving is
  # the beat that closes the row.
  context "when the matching application is already settled" do
    let!(:job) { user.job_applications.create!(company: "iCapital", status: :rejected) }

    it "still offers, against the row it belongs to" do
      expect(call.metadata["job_application_id"]).to eq(job.id)
    end
  end
end
