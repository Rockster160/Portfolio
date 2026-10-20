require "rails_helper"

RSpec.describe ByteInterviewPrep do
  let(:user) { User.me }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }
  let(:agenda) { create(:agenda, user: user) }
  let(:job) {
    user.job_applications.create!(company: "Bluestaq", role: "Principal Engineer")
  }
  # The internal row: the one a `scheduled` beat writes, carrying the link to
  # the application in its first line. See JobNote#item_notes.
  let(:item) {
    create(
      :agenda_item,
      agenda:   agenda,
      kind:     :event,
      name:     "Interview: Bluestaq",
      start_at: tz.parse("2026-10-20 14:00:00"),
      end_at:   tz.parse("2026-10-20 15:00:00"),
      notes:    "#{job.interview_url}\n\n45 minutes with Casey, the hiring manager.",
    )
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ByteLocal).to receive_messages(reset_claude_session: true, deliver: true)
    allow(BuddyDeliverWorker).to receive(:perform_async)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  describe ".application_for" do
    # The first line of the notes is the handle, because it is the one thing
    # every row a job beat writes is guaranteed to carry.
    it "finds the application off the link in the first line" do
      expect(described_class.application_for(item, user)).to eq(job)
    end

    # ONE INTERVIEW IS TWO ROWS. The company's synced invite has the same
    # minute and a title that matches the same listener; its notes are the
    # event description, which goes back out to the attendees. Only ours
    # carries the link, and that is what tells them apart.
    it "ignores the company's own invite, which carries no link" do
      invite = create(
        :agenda_item,
        agenda:   agenda,
        kind:     :event,
        name:     "Interview - Rocco Nicholls / Bluestaq",
        start_at: item.start_at,
        end_at:   item.end_at,
        notes:    "Join the Zoom at https://zoom.us/j/123",
      )

      expect(described_class.application_for(invite, user)).to be_nil
    end

    it "ignores a link to somebody else's application" do
      other = create(:user).job_applications.create!(company: "Elsewhere")
      item.update!(notes: other.interview_url)

      expect(described_class.application_for(item, user)).to be_nil
    end

    it "is nil for an event with no notes at all" do
      item.update!(notes: nil)

      expect(described_class.application_for(item, user)).to be_nil
    end
  end

  describe ".conversation" do
    it "runs in claude mode, which is the only mode that reaches the Mac" do
      convo = described_class.conversation(user)

      expect(convo.mode).to eq("claude")
      expect(convo.metadata["cwd"]).to eq(described_class::CWD)
    end

    # The whole read-only guarantee is this one value: `ask` is as wide as
    # whatever has ever been tapped "always allow".
    it "sits in read mode, which no allow rule can widen" do
      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
    end

    it "puts read mode back when the pwd bar has toggled it" do
      convo = described_class.conversation(user)
      convo.update!(metadata: convo.metadata.merge("permission_mode" => "auto"))

      expect(described_class.conversation(user).metadata["permission_mode"]).to eq("read")
    end

    it "stays out of the thread list" do
      expect(described_class.conversation(user)).to be_archived
    end

    it "reuses the one thread rather than making one per interview" do
      first = described_class.conversation(user)

      expect(described_class.conversation(user).id).to eq(first.id)
    end
  end

  describe ".run!" do
    it "posts the prompt into the prep thread" do
      expect { described_class.run!(user, application: job, item: item) }.to change {
        described_class.conversation(user).byte_messages.count
      }.by(1)
    end

    # NOTHING IS SAID WHEN IT STARTS. An hour before an interview, a buzz
    # saying "researching" costs attention and carries nothing.
    it "keeps the prompt out of the thread and off his phone" do
      described_class.run!(user, application: job, item: item)
      posted = described_class.conversation(user).byte_messages.order(:id).last

      expect(posted.metadata["hidden"]).to be_truthy
      expect(posted.direction).to eq("outbound")
      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    # The thread is reused for every interview, so a resumed session arrives
    # already believing it knows which company this is.
    it "starts a fresh session" do
      expect(ByteLocal).to receive(:reset_claude_session)

      described_class.run!(user, application: job, item: item)
    end

    it "stamps which application and which booking it is for" do
      described_class.run!(user, application: job, item: item)
      posted = described_class.conversation(user).byte_messages.order(:id).last

      expect(posted.metadata["job_application_id"]).to eq(job.id)
      expect(posted.metadata["agenda_item_id"]).to eq(item.id)
      expect(posted.metadata["interview_at"]).to eq(item.start_at.iso8601)
    end

    # A touched event re-arms its trigger and can fire twice; a second session
    # spends ten minutes to produce a duplicate of the first.
    it "stands down when a brief for that booking is already being written" do
      described_class.run!(user, application: job, item: item)

      expect(described_class.run!(user, application: job, item: item)).to eq(:already_prepped)
    end

    it "stands down when a brief for that booking has already landed" do
      job.preps.create!(body: "already written", agenda_item: item)

      expect(described_class.run!(user, application: job, item: item)).to eq(:already_prepped)
    end

    # Two interviews with one company on one day is a real shape: a screen in
    # the morning and the hiring manager in the afternoon are two conversations
    # and want two briefs.
    it "writes a second brief for a second booking the same day" do
      described_class.run!(user, application: job, item: item)
      later = create(
        :agenda_item,
        agenda:   agenda,
        kind:     :event,
        name:     "Interview: Bluestaq",
        start_at: item.start_at + 3.hours,
        end_at:   item.start_at + 4.hours,
        notes:    job.interview_url,
      )

      expect(described_class.run!(user, application: job, item: later)).to eq(:sent)
    end

    it "runs anyway when it is kicked by hand" do
      described_class.run!(user, application: job, item: item)

      expect(described_class.run!(user, application: job, item: item, force: true)).to eq(:sent)
    end
  end

  describe ".dispatch" do
    # Both machines run the schedule against the same database, both answer
    # "no" to already-prepped, and ByteLocal reaches the SAME Mac from either.
    it "does nothing outside production" do
      expect(described_class.dispatch(user, item.id)).to eq(:not_production)
    end

    context "when it is production" do
      before { allow(Rails.env).to receive(:production?).and_return(true) }

      it "starts the session for the interview on that row" do
        expect(described_class.dispatch(user, item.id)).to eq(:sent)
      end

      # The listener matches any event with "interview" in the title, which is
      # the right net to cast - this is where the rest fall out.
      it "stands down on an event that is not one of his interviews" do
        other = create(
          :agenda_item, agenda: agenda, kind: :event, name: "Interview prep",
          start_at: item.start_at, end_at: item.end_at
        )

        expect(described_class.dispatch(user, other.id)).to eq(:not_an_interview)
      end

      it "stands down when the event has been deleted since" do
        expect(described_class.dispatch(user, 0)).to eq(:no_event)
      end
    end
  end

  describe "the prompt" do
    subject(:prompt) { described_class::Brief.text(job, item, user: user) }

    it "says which company, which role, and when" do
      expect(prompt).to include("Bluestaq")
      expect(prompt).to include("Principal Engineer")
      expect(prompt).to include("Tuesday October 20, 2026 at 2:00 PM")
    end

    # What the row says is how the kind of conversation gets decided, and the
    # link line is dropped because it is only how we got here.
    it "carries what the calendar row says, without the link line" do
      expect(prompt).to include("45 minutes with Casey, the hiring manager.")
      expect(prompt).not_to include(job.interview_url)
    end

    it "carries the timeline, newest first" do
      job.notes.create!(
        tag: :recruiter_call, occurred_at: 3.days.ago,
        spoke_to: "Dana", body: "Screen went well, moving to the hiring manager."
      )

      expect(prompt).to include("Recruiter call")
      expect(prompt).to include("Screen went well")
      expect(prompt).to include("Dana")
    end

    it "says plainly when there is nothing written down yet" do
      expect(prompt).to include("Nothing is logged against this one yet")
    end

    # The kind of conversation decides everything else, and getting it wrong
    # prepares him for the wrong hour.
    it "asks it to work out what kind of conversation this is first" do
      expect(prompt).to include("WORK OUT WHAT KIND OF CONVERSATION THIS IS FIRST")
      expect(prompt).to include("recruiter")
      expect(prompt).to include("technical")
    end

    it "names where his own background is written down" do
      expect(prompt).to include(described_class::RESUME_REPO)
      expect(prompt).to include("profile.yml")
      expect(prompt).to include("interview-answers.md")
    end

    # A brief that says "use #3" has sent him to another page to do the one
    # thing it was written to save him - and the answers file is on a drive
    # the phone reading the brief cannot open at all.
    it "asks for the written answers themselves, not a pointer to them" do
      expect(prompt).to include("The answers themselves")
      expect(prompt).to include("WHATEVER THE BRIEF NAMES, THE BRIEF CARRIES")
      expect(prompt).to include("Verbatim, as the file has it")
    end

    it "points at the local posting, which outlives their listing" do
      job.update!(jobhunt_job_id: 412)

      expect(prompt).to include("#{described_class::JOBHUNT_URL}/jobs/412")
    end

    # There is nobody in front of this run, so a question is a stall and a
    # refusal retried is the rest of the hour.
    it "tells the run not to ask and not to retry a refusal" do
      expect(prompt).to include("do not ask a question")
      expect(prompt).to include("do not retry a refusal")
    end

    it "asks for the two opening lines it is parsed by" do
      expect(prompt).to include("KIND:")
    end

    it "says the brief is saved for him, so the session does not go looking" do
      expect(prompt).to include("saved and linked for me automatically")
    end
  end

  describe ".submit!" do
    let(:report) {
      "# Hiring manager call with Bluestaq\nKIND: manager\n\n## The company\nThey build data platforms.\n"
    }

    before { user.byte_conversations.create!(name: "Byte", mode: :buddy) }

    def write_the_brief(body: nil, metadata: {})
      described_class.run!(user, application: job, item: item)
      prompt = described_class.conversation(user).byte_messages.order(:id).last

      described_class.conversation(user).byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         body || report,
        delivered_at: Time.current,
        metadata:     { "kind" => "claude", "in_reply_to" => prompt.id }.merge(metadata),
      )
    end

    it "files the brief against the application" do
      expect { described_class.submit!(write_the_brief) }.to change { job.preps.reload.size }.by(1)
    end

    it "keeps what it was for, so the brief outlives the calendar row" do
      described_class.submit!(write_the_brief)
      prep = job.preps.first

      expect(prep.agenda_item_id).to eq(item.id)
      expect(prep.interview_at).to eq(item.start_at)
      expect(prep.kind).to eq("manager")
      expect(prep.title).to eq("Hiring manager call with Bluestaq")
    end

    # The session's own thread is archived machinery. The brief is read by
    # following a link from the thread he actually reads.
    it "sends him one message carrying the link" do
      described_class.submit!(write_the_brief)
      prep = job.preps.first
      said = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

      expect(said.body).to include(prep.prep_url)
      expect(said.metadata["source"]).to eq("interview_prep")
    end

    it "does not paste the brief into the thread" do
      described_class.submit!(write_the_brief)
      said = ByteConversation.for_self_initiated(user).byte_messages.order(:id).last

      expect(said.body).not_to include("They build data platforms")
    end

    # The prep thread is a real thread somebody can type in.
    it "ignores a reply that answers nothing" do
      message = described_class.conversation(user).byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "# Hi\nKIND: manager\n\nhello",
        metadata: { "kind" => "claude" }
      )

      expect(described_class.submit!(message)).to be(false)
      expect(job.preps.reload.size).to eq(0)
    end

    it "ignores anything that is not the session's own reply" do
      expect(described_class.submit!(write_the_brief(metadata: { "kind" => "buddy" }))).to be(false)
    end

    # An id out of message metadata is not a fact about whose application it
    # is. Nothing reaching here today carries somebody else's, and the brief
    # must still never land on their row.
    it "files nothing against somebody else's application" do
      other = create(:user).job_applications.create!(company: "Elsewhere")
      message = write_the_brief
      described_class.conversation(user).byte_messages.find(
        message.metadata["in_reply_to"],
      ).update!(metadata: { "interview_prep" => true, "job_application_id" => other.id })

      expect(described_class.submit!(message)).to be(false)
      expect(other.preps.reload).to be_empty
    end

    it "ignores a reply in any other thread" do
      convo = user.byte_conversations.create!(name: "Something else", mode: :claude)
      message = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: report,
        metadata: { "kind" => "claude" }
      )

      expect(described_class.submit!(message)).to be(false)
    end

    # An event deleted while the session was researching it, or a recurring
    # occurrence whose id is not a number: the brief is still perfectly good
    # and must not be lost to a foreign key.
    it "files the brief even when the booking has gone" do
      message = write_the_brief
      item.destroy!

      expect(described_class.submit!(message)).to be(true)
      expect(job.preps.first.agenda_item_id).to be_nil
    end
  end

  # An archived thread is machinery, not a place. Both Claude-session jobs hand
  # the finished thing over properly; the session's own reply buzzing as well
  # is the same work announcing itself twice, the second time as markdown.
  describe "the session's own reply" do
    it "does not push" do
      convo = described_class.conversation(user)
      message = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "the brief",
        metadata: { "kind" => "claude" }
      )

      ByteNotifier.notify(user, message)

      expect(WebPushNotifications).not_to have_received(:send_to_byte)
    end

    it "still pushes from a thread he reads" do
      convo = user.byte_conversations.create!(name: "Byte", mode: :buddy)
      message = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "hello",
        metadata: { "kind" => "buddy" }
      )

      ByteNotifier.notify(user, message)

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end
  end
end
