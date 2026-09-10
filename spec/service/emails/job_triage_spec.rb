require "rails_helper"

# The ardesian.com addresses have been on scraped lists for years, so the mail
# that matters (an ATS saying an application moved) arrives in a stream of cold
# sales that is deliberately written to look like opportunity. These are the
# calls that were getting made wrong.
RSpec.describe Emails::JobTriage do
  let!(:user) { User.me || create(:user, id: 1, username: "Rocco") }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  def email!(address:, subject:, blurb: "Hello there.", name: nil)
    user.emails.create!(
      mail_id:            "m-#{SecureRandom.hex(4)}",
      timestamp:          Time.current,
      direction:          :inbound,
      inbound_mailboxes:  [{ name: nil, address: "rocco@ardesian.com" }],
      outbound_mailboxes: [{ name: name, address: address }],
      subject:            subject,
      blurb:              blurb,
    )
  end

  # A queue rather than `and_return(a, b)`: every call builds a fresh client, so
  # any_instance_of would hand back the first reply forever.
  def stub_model(*texts)
    queue = texts.dup
    allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |*|
      {
        ok:    true,
        text:  (queue.length > 1 ? queue.shift : queue.first),
        model: "gpt-5.4-mini",
        usage: FakeBuddyClient::DEFAULT_USAGE,
      }
    }
  end

  def verdict_json(job:, kind: "application status", company: "Netflix", headline: "They got it.")
    { job: job, kind: kind, company: company, headline: headline }.to_json
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  describe "the free gate" do
    it "drops the machines that make up most of the inbox" do
      {
        "no.reply.alerts@chase.com"                  => :ignored,
        "shipment-tracking@amazon.com"               => :ignored,
        "venmo@venmo.com"                            => :ignored,
        "support@digitalocean.com"                   => :ignored,
        "noreply@github.com"                         => :ignored,
        "bot@notifications.heroku.com"               => :ignored,
        "invoicing@aws.com"                          => :ignored,
        "subscription.service@subscriptions.ssa.gov" => :ignored,
      }.each do |address, reason|
        expect(described_class.skip_reason(email!(address: address, subject: "x"))).to eq(reason),
          "expected #{address} to be #{reason}"
      end
    end

    it "drops the board digests" do
      %w[
        jobs@my.theladders.com
        jobs@inform.theladders.com
        apply4me@a4m.theladders.com
        jobalerts-noreply@linkedin.com
        dice@connect.dice.com
      ].each do |address|
        reason = described_class.skip_reason(email!(address: address, subject: "x"))
        expect(reason).to eq(:job_spam), "expected #{address} to be job_spam"
      end
    end

    # The whole reason JOB_SPAM_SENDERS lists addresses instead of domains.
    # TheLadders sends the digests AND holds an open application.
    it "does not blanket-block a board that is also an employer" do
      email = email!(address: "recruiting@theladders.com", subject: "Next steps")
      expect(described_class.skip_reason(email)).to be_nil
    end

    # GitHub the noise-maker and GitHub the employer are different domains, and
    # only one of them is on the list.
    it "blocks github.com while leaving GitHub's ATS reachable" do
      noise = email!(address: "noreply@github.com", subject: "x")
      ats   = email!(address: "githubinc+autoreply@talent.icims.com", subject: "Thank You")

      expect(described_class.skip_reason(noise)).to eq(:ignored)
      expect(described_class.skip_reason(ats)).to be_nil
    end

    it "never spends a call on a listed sender" do
      expect_any_instance_of(Buddy::GPT::Client).not_to receive(:stream)
      chase = email!(address: "no.reply.alerts@chase.com", subject: "x")
      expect(described_class.triage!(chase)).to be_nil
    end
  end

  describe "what the model is told" do
    it "carries the open applications so 'already exists' is answerable" do
      JobApplication.create!(user: user, company: "Netflix", color: "#388bfd", status: :active)
      JobApplication.create!(user: user, company: "Anrok", color: "#a371f7", status: :active)
      JobApplication.create!(user: user, company: "Visa", color: "#e3b341", status: :rejected)

      text = described_class.instructions(user)
      expect(text).to include("Anrok, Netflix")
      expect(text).not_to include("Visa") # settled; not something to expect mail about
      expect(text).to include("EVIDENCE, NOT A GATE")
    end

    it "says so plainly when there is nothing on file" do
      expect(described_class.instructions(user)).to include("(none on file)")
    end

    it "sends the sender, the subject and the blurb" do
      block = described_class.email_block(
        email!(
          address: "careers@jobs.netflix.com", name: "Netflix", subject: "We got it",
          blurb: "Your application for Senior Software Engineer."
        ),
      )
      expect(block).to include("Netflix <careers@jobs.netflix.com>")
      expect(block).to include("Subject: We got it")
      expect(block).to include("Senior Software Engineer")
    end
  end

  describe "reading the verdict" do
    it "survives the fenced block the model likes to add" do
      parsed = described_class.parse("```json\n#{verdict_json(job: true)}\n```")
      expect(parsed[:job]).to be(true)
      expect(parsed[:company]).to eq("Netflix")
    end

    it "returns nil rather than guessing when there is no JSON at all" do
      expect(described_class.parse("I think this one is probably fine?")).to be_nil
    end
  end

  describe "delivery" do
    let(:email) {
      email!(
        address: "careers@jobs.netflix.com", name: "Netflix",
        subject: "We have received your application"
      )
    }

    # A plain card is what's left when the classifier named no company: there is
    # no row to hang a beat on and nothing to propose starting, so seeing it is
    # the whole of what can be offered.
    it "posts one card into the thread and pushes it" do
      stub_model(verdict_json(
                   job: true, kind: "application status", company: nil,
                   headline: "Netflix has it."
      ))

      message = described_class.triage!(email)

      expect(message).to be_present
      expect(message.byte_conversation).to eq(convo)
      expect(message.body).to include("Netflix has it.")
      expect(message.body).to include("We have received your application")
      expect(message.body).to include("application status")
      expect(message.body).to include("/emails/#{email.id}")
      expect(message.metadata.to_h).to include("kind" => "system", "source" => "job_mail_triage")
      expect(message.metadata.to_h["email_id"]).to eq(email.id)
      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        hash_including(title: "Netflix has it."),
      )
    end

    it "says nothing at all when the answer is no" do
      pitch = verdict_json(
        job:      false,
        kind:     "web design outreach",
        company:  nil,
        headline: "Someone wants to redesign the site.",
      )
      stub_model(pitch)

      expect { described_class.triage!(email) }.not_to change(ByteMessage, :count)
    end

    it "stays quiet when the model call fails" do
      allow_any_instance_of(Buddy::GPT::Client).to receive(:stream).and_return(
        { ok: false, error: "boom", model: "gpt-5.4-mini" },
      )

      expect { described_class.triage!(email) }.not_to change(ByteMessage, :count)
    end

    # A Sidekiq retry, or ReceiveEmailWorker running again over the same S3
    # object, both arrive back here.
    it "is one card per email however many times it runs" do
      stub_model(verdict_json(job: true, company: nil))

      expect { described_class.triage!(email) }.to change(ByteMessage, :count).by(1)
      expect { described_class.triage!(email) }.not_to change(ByteMessage, :count)
    end

    it "remembers the verdict on the email itself, yes or no" do
      stub_model(verdict_json(job: true, kind: "application status", headline: "Netflix has it."))
      described_class.triage!(email)

      expect(email.reload.job_triage).to include(
        job: true, kind: "application status", company: "Netflix",
      )
      expect(email.job_mail?).to be(true)
      expect(email.job_triage[:at]).to be_present
    end

    it "remembers a no as firmly as a yes" do
      pitch = verdict_json(
        job: false, kind: "web design outreach", company: nil,
        headline: "Someone wants to redesign the site."
      )
      stub_model(pitch)
      described_class.triage!(email)

      expect(email.reload.triaged?).to be(true)
      expect(email.job_mail?).to be(false)
    end

    it "bills the call to its own kind" do
      stub_model(verdict_json(job: true, company: nil))
      described_class.triage!(email)

      expect(BuddyUsage.last.kind).to eq("job_triage")
    end
  end

  # Mail that belongs to something already on the board is worth more than a
  # card: it is the one moment the beat can be written down while it is in
  # front of them.
  describe "when the company is already on the board" do
    let(:email) {
      email!(
        address: "no-reply@hire.lever.co", name: "Lever",
        subject: "Thank you for your time with CSC Generation"
      )
    }

    before do
      JobApplication.where(user: user).destroy_all
      JobApplication.create!(
        user: user, company: "CSC Generation", status: :active,
        color: JobApplication::COLORS.first
      )
      stub_model(verdict_json(
                   job: true, kind: "application status",
                   company: "CSC Generation, Inc.", headline: "CSC Generation followed up."
      ))
    end

    it "hands Buddy a seed to speak from instead of posting a card" do
      message = described_class.triage!(email)

      expect(message.direction).to eq("outbound")
      expect(message.body).to include("CSC Generation")
      expect(message.body).to include("Email id: #{email.id}")
      expect(message.body).to include("add_job_note")
      expect(message.metadata.to_h["job_application_id"]).to be_present
    end

    # Nothing is written on arrival, but the question is the CARD, not a
    # sentence: add_job_note is level 3, so calling it proposes and waits.
    it "tells Buddy to propose it as a card rather than ask in prose" do
      message = described_class.triage!(email)

      expect(message.body).to include("CALL add_job_note")
      expect(message.body).to include("do not offer to, do not ask")
    end

    it "keeps the seed out of the thread" do
      message = described_class.triage!(email)

      expect(message.metadata.to_h["hidden"]).to be(true)
    end

    it "proposes starting a row when the company isn't on the board" do
      JobApplication.where(user: user).destroy_all

      message = described_class.triage!(email)

      expect(message.direction).to eq("outbound")
      expect(message.body).to include("NOT on their board yet")
      expect(message.body).to include("CALL add_job_application")
      expect(message.metadata.to_h["hidden"]).to be(true)
    end
  end
end
