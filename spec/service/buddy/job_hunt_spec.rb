require "rails_helper"

# The board and the mail about it, together. Byte can only offer to log a beat
# if she can see both the application to hang it on and the message it came in.
RSpec.describe "Buddy job hunt tools" do
  let(:user) { User.me }

  def ctx = Buddy::ToolContext.new(user)

  def run(name, payload)
    tool = Buddy::Tools[name]
    confirm = tool[:confirm].call(payload, ctx)
    [tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx), confirm]
  end

  def application!(company, status: :active, role: nil)
    JobApplication.create!(
      user: user, company: company, role: role, status: status,
      color: JobApplication::COLORS.first
    )
  end

  def job_mail!(subject:, company:, headline: "They wrote back.", logged: nil, at: 1.day.ago)
    Email.create!(
      user:               user,
      mail_id:            "jh-#{SecureRandom.hex(4)}",
      timestamp:          at,
      direction:          :inbound,
      inbound_mailboxes:  [{ name: nil, address: "rocco@ardesian.com" }],
      outbound_mailboxes: [{ name: "Talent Team", address: "careers@example.com" }],
      subject:            subject,
      blurb:              "Some words.",
      job_triage:         {
        job:         true,
        kind:        "application status",
        company:     company,
        headline:    headline,
        at:          at.iso8601,
        job_note_id: logged,
      }.compact,
    )
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    JobApplication.where(user: user).destroy_all
    Email.where(user: user).delete_all
  end

  describe Buddy::JobHunt do
    it "is nothing at all when there is no job search" do
      expect(described_class.context_for(user)).to be_nil
    end

    it "carries the live board with what last happened on each" do
      job = application!("Netflix", role: "Senior Engineer")
      job.notes.create!(tag: :applied, occurred_at: 3.days.ago, body: "Sent it")
      application!("Visa", status: :rejected)

      payload = described_class.context_for(user)
      companies = payload[:applications].pluck(:company)

      expect(companies).to eq(["Netflix"])
      expect(payload[:applications].first).to include(role: "Senior Engineer", notes: 1)
      expect(payload[:applications].first[:last_beat]).to include("Applied on")
    end

    it "surfaces a follow-up that is owed" do
      job = application!("Samsara")
      job.notes.create!(tag: :recruiter_call, occurred_at: 2.days.ago, follow_up_at: 1.day.from_now)

      expect(described_class.context_for(user)[:applications].first[:follow_up]).to be_present
    end

    # The field that turns a list of messages into something answerable.
    it "says which mail is already on the board and which is not" do
      application!("Netflix")
      job_mail!(subject: "We got it", company: "Netflix")
      job_mail!(subject: "Already filed", company: "Netflix", logged: 99)

      mail = described_class.context_for(user)[:recent_mail]

      expect(mail.find { |m| m[:subject] == "We got it" }[:logged]).to be(false)
      expect(mail.find { |m| m[:subject] == "Already filed" }[:logged]).to be(true)
    end

    it "leaves out mail that was triaged and turned down" do
      application!("Netflix")
      email = job_mail!(subject: "Website redesign?", company: nil)
      email.update!(job_triage: { job: false, kind: "sales outreach" })

      expect(described_class.context_for(user)[:recent_mail]).to be_empty
    end

    # The section is useless if get_context can't be asked for it, and it is
    # gated on a feature that is off for everyone until granted.
    it "is reachable through get_context once the feature is held" do
      expect(Buddy::GPT::ContextTool::SECTIONS).to include(:job_search)

      user.update!(buddy_features: Array(user.buddy_features).map(&:to_s) - ["job_search"])
      expect(Buddy::Features.hidden_sections(user)).to include(:job_search)

      user.update!(buddy_features: Array(user.buddy_features).map(&:to_s) + ["job_search"])
      expect(Buddy::Features.hidden_sections(user)).not_to include(:job_search)
      expect(Buddy::Features.allows_tool?(user, Buddy::Tools[:add_job_note])).to be(true)
    end

    it "links one application by id rather than one url per row" do
      application!("Netflix")
      expect(described_class.context_for(user)[:url]).to end_with("/interviews/{id}")
    end
  end

  # The question this whole feature has to survive: it is one person's job hunt,
  # and nobody else's companion should know it exists.
  describe "who can see any of it" do
    let(:other) {
      User.find_by(id: 4) || create(:user, id: 4, username: "Eve")
    }

    before { other.update!(buddy_features: Buddy::Features::DEFAULT.map(&:to_s)) }

    # The bug this pins: SECTIONS drives DEFAULT, so adding job_search there
    # without also listing it handed the tool to every account created after.
    it "is not part of what a new account is handed" do
      expect(Buddy::Features::DEFAULT).not_to include(:job_search)
      expect(Buddy::Features.enabled?(other, :job_search)).to be(false)
    end

    # Out of DEFAULT only ever meant "not handed over at signup". The ask was
    # that it be HIS, so it's OWNER_ONLY now and `enabled_for` subtracts it
    # from everybody else - a grant that reaches this row does nothing.
    it "keeps the tool out of the schema even if the feature is granted" do
      names = Buddy::Tools.function_schemas(user: other).pluck(:name)
      expect(names).not_to include(:add_job_note)

      other.update!(buddy_features: Array(other.buddy_features).map(&:to_s) + ["job_search"])
      granted = Buddy::Tools.function_schemas(user: other.reload).pluck(:name)
      expect(granted).not_to include(:add_job_note)
      expect(Buddy::Features.enabled?(other, :job_search)).to be(false)
    end

    it "leaves it working for the owner" do
      expect(Buddy::Tools.function_schemas(user: user).pluck(:name)).to include(:add_job_note)
    end

    it "keeps the section out of get_context and out of the built context" do
      expect(Buddy::Features.hidden_sections(other)).to include(:job_search)
      expect(Buddy::GPT::ContextTool.withheld(other)).to include(:job_search)
      offered = Buddy::GPT::ContextTool.schema(user: other)
      nameable = offered.dig(:parameters, :properties, :sections, :items, :enum)
      expect(nameable).not_to include(:job_search)
    end

    it "does not offer them the interviews page" do
      expect(Buddy::AppPages.for_user(other).pluck(:name)).not_to include(:interviews)

      other.update!(buddy_features: Array(other.buddy_features).map(&:to_s) + ["job_search"])
      expect(Buddy::AppPages.for_user(other.reload).pluck(:name)).not_to include(:interviews)
      expect(Buddy::AppPages.for_user(user).pluck(:name)).to include(:interviews)
    end

    # Belt and braces under the feature gate: even if something reached the
    # board directly, it is scoped by user, so nobody is one bug away from
    # reading his applications the way the delivery list would have leaked.
    it "shows them their own empty board rather than anyone else's" do
      application!("Netflix")
      other.update!(buddy_features: Array(other.buddy_features).map(&:to_s) + ["job_search"])

      expect(Buddy::JobHunt.context_for(other.reload)).to be_nil
      expect(Buddy::JobHunt.resolve_application(other, "Netflix")).to be_nil
    end
  end

  describe "add_job_note" do
    # Prod 5759, and the reason this is the one job tool that must not write on
    # arrival. He said Corporate Tools; the row that got settled as rejected was
    # CSC Generation, because Corporate Tools was already closed and so wasn't
    # on the visible board. At level 2 that wrote the moment it was said and
    # the read-back was the only thing standing in the way.
    it "waits for a tap instead of writing on arrival" do
      expect(Buddy::Tools[:add_job_note][:level]).to eq(3)
      expect(Buddy::Tools[:add_job_note][:auto]).to be(false)
    end

    # A settling tag doesn't just add a row - it closes the application. That
    # is the half that made being wrong expensive.
    it "still carries a way back once it has been tapped" do
      application!("Netflix")
      result, = run(:add_job_note, { company: "Netflix", tag: :rejected, note: "no thanks" })

      expect(result[:settled]).to be(true)
      expect(Buddy::Reverter.descriptors(result)).to be_present
    end

    it "logs a beat against a fuzzily-named company" do
      application!("CSC Generation")

      result, confirm = run(:add_job_note, {
        company: "CSC Generation, Inc.",
        note:    "They want to book a call",
        tag:     :heard_back,
      })

      expect(confirm[:summary]).to include("CSC Generation")
      expect(result[:company]).to eq("CSC Generation")
      expect(JobNote.last.tag).to eq("heard_back")
    end

    it "refuses a company that isn't on the live board" do
      application!("Visa", status: :rejected)

      expect { run(:add_job_note, { company: "Visa", note: "hi", tag: :note }) }.to raise_error(/no live application/)
    end

    it "does not log a bare note with nothing in it" do
      application!("Netflix")

      expect { run(:add_job_note, { company: "Netflix", note: "  ", tag: :note }) }.to raise_error(/say what happened/)
    end

    # The point of the whole feature: the note carries the email's date, its
    # link, and a mark back on the email saying it has been dealt with.
    it "stamps the note from the email and marks the email logged" do
      application!("Netflix")
      email = job_mail!(
        subject: "We received your application", company: "Netflix",
        at: 3.days.ago
      )

      result, = run(:add_job_note, {
        company:  "Netflix",
        note:     "Application received",
        tag:      :heard_back,
        email_id: email.id,
      })

      note = JobNote.last
      expect(note.occurred_at.to_date).to eq(3.days.ago.to_date)
      expect(note.source).to eq("Email")
      expect(note.url).to include("/emails/#{email.id}")
      expect(email.reload.job_triage[:job_note_id]).to eq(note.id)
      expect(result[:settled]).to be(false)
    end

    it "refuses an email id that isn't theirs" do
      application!("Netflix")

      expect { run(:add_job_note, { company: "Netflix", note: "x", tag: :note, email_id: 0 }) }.to raise_error(/no email/)
    end

    describe "a tag that settles the whole application" do
      it "closes the job and says so" do
        application!("Upstart")

        result, confirm = run(:add_job_note, {
          company: "Upstart", note: "No thanks", tag: :rejected
        })

        expect(confirm[:summary]).to include("closes it as rejected")
        expect(result[:settled]).to be(true)
        expect(JobApplication.find_by(company: "Upstart").status).to eq("rejected")
      end

      # JobNote#settle_application bails on destroy, so undoing the note alone
      # would take the row away and leave the application marked rejected.
      it "puts the status back when the note is undone" do
        application!("Upstart")
        result, = run(:add_job_note, { company: "Upstart", note: "No thanks", tag: :rejected })

        result[:reverts].each { |rv| Buddy::Reverter.call(rv) }

        expect(JobNote.count).to be_zero
        expect(JobApplication.find_by(company: "Upstart").status).to eq("active")
      end

      it "stashes only the one descriptor when nothing was settled" do
        application!("Netflix")
        result, = run(:add_job_note, { company: "Netflix", note: "Called", tag: :recruiter_call })

        expect(result[:reverts].length).to eq(1)
      end
    end
  end
end
