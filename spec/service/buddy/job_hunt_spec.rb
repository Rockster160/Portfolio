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

    # A closed application is still something they talk about; `status` is what
    # stops it reading as a live lead.
    it "carries the whole board, what last happened, what is owed, and which mail is filed", :aggregate_failures do
      netflix = application!("Netflix", role: "Senior Engineer")
      netflix.notes.create!(tag: :applied, occurred_at: 3.days.ago, body: "Sent it")
      application!("Visa", status: :rejected)
      application!("Samsara").notes.create!(tag: :recruiter_call, occurred_at: 2.days.ago, follow_up_at: 1.day.from_now)
      job_mail!(subject: "We got it", company: "Netflix")
      job_mail!(subject: "Already filed", company: "Netflix", logged: 99)
      job_mail!(subject: "Website redesign?", company: nil).update!(job_triage: { job: false, kind: "sales outreach" })

      payload = described_class.context_for(user)
      rows = payload[:applications]
      row = rows.find { |a| a[:company] == "Netflix" }
      expect(row).to include(role: "Senior Engineer", notes: 1)
      expect(row[:last_beat]).to be_present
      expect(rows.find { |a| a[:company] == "Visa" }[:status]).to eq("rejected")
      expect(rows.find { |a| a[:company] == "Samsara" }[:follow_up]).to be_present

      mail = payload[:recent_mail]
      expect(mail.pluck(:subject)).to contain_exactly("We got it", "Already filed")
      expect(mail.find { |m| m[:subject] == "We got it" }[:logged]).to be(false)
      expect(mail.find { |m| m[:subject] == "Already filed" }[:logged]).to be(true)
      # One application link by id rather than one url per row.
      expect(payload[:url]).to end_with("/interviews/{id}")
    end

    it "is reachable through get_context only once the feature is held", :aggregate_failures do
      user.update!(buddy_features: Array(user.buddy_features).map(&:to_s) - ["job_search"])
      expect(Buddy::Features.hidden_sections(user)).to include(:job_search)

      user.update!(buddy_features: Array(user.buddy_features).map(&:to_s) + ["job_search"])
      expect(Buddy::Features.hidden_sections(user)).not_to include(:job_search)
      expect(Buddy::Features.allows_tool?(user, Buddy::Tools[:add_job_note])).to be(true)
    end
  end

  # One person's job hunt: nobody else's companion should know it exists, even
  # if the feature is granted to them.
  describe "who can see any of it" do
    let(:other) {
      User.find_by(id: 4) || create(:user, id: 4, username: "Eve")
    }

    before { other.update!(buddy_features: Buddy::Features::DEFAULT.map(&:to_s)) }

    def grant_other!
      other.update!(buddy_features: Array(other.buddy_features).map(&:to_s) + ["job_search"])
      other.reload
    end

    it "keeps the tool, the section, the page and the board from anyone but the owner, granted or not", :aggregate_failures do
      application!("Netflix")

      expect(Buddy::Features.enabled?(other, :job_search)).to be(false)
      expect(Buddy::Tools.function_schemas(user: other).pluck(:name)).not_to include(:add_job_note)
      expect(Buddy::AppPages.for_user(other).pluck(:name)).not_to include(:interviews)

      grant_other!
      expect(Buddy::Features.enabled?(other, :job_search)).to be(false)
      expect(Buddy::Tools.function_schemas(user: other).pluck(:name)).not_to include(:add_job_note)
      expect(Buddy::Features.hidden_sections(other)).to include(:job_search)
      expect(Buddy::GPT::ContextTool.withheld(other)).to include(:job_search)
      nameable = Buddy::GPT::ContextTool.schema(user: other).dig(:parameters, :properties, :sections, :items, :enum)
      expect(nameable).not_to include(:job_search)
      expect(Buddy::AppPages.for_user(other).pluck(:name)).not_to include(:interviews)
      # Scoped by user underneath the gate too.
      expect(Buddy::JobHunt.context_for(other)).to be_nil
      expect(Buddy::JobHunt.resolve_application(other, "Netflix")).to be_nil
    end

    it "leaves it working for the owner", :aggregate_failures do
      expect(Buddy::Tools.function_schemas(user: user).pluck(:name)).to include(:add_job_note)
      expect(Buddy::AppPages.for_user(user).pluck(:name)).to include(:interviews)
    end
  end

  describe "add_job_note" do
    it "logs a beat against a fuzzily-named company, including a settled one", :aggregate_failures do
      application!("CSC Generation")
      application!("Corporate Tools", status: :rejected)

      result, = run(:add_job_note, { company: "CSC Generation, Inc.", note: "They want to book a call", tag: :heard_back })
      expect(result[:company]).to eq("CSC Generation")
      expect(JobNote.last.tag).to eq("heard_back")
      # Only the one descriptor when nothing was settled.
      expect(result[:reverts].length).to eq(1)

      result, = run(:add_job_note, { company: "Corporate Tools", note: "no reason given", tag: :note })
      expect(result[:company]).to eq("Corporate Tools")
      expect(result[:status]).to eq("rejected")
    end

    it "refuses a company not on the board, an empty note, or an email that isn't theirs", :aggregate_failures do
      application!("Netflix")

      expect { run(:add_job_note, { company: "Wayfarer Labs", note: "hi", tag: :note }) }.to raise_error(RuntimeError)
      expect { run(:add_job_note, { company: "Netflix", note: "  ", tag: :note }) }.to raise_error(RuntimeError)
      expect { run(:add_job_note, { company: "Netflix", note: "x", tag: :note, email_id: 0 }) }.to raise_error(RuntimeError)
      expect(JobNote.count).to be_zero
    end

    it "stamps the note from the email and marks the email logged", :aggregate_failures do
      application!("Netflix")
      email = job_mail!(subject: "We received your application", company: "Netflix", at: 3.days.ago)

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

    it "keeps the mail's own words when it revises the row the mail filed", :aggregate_failures do
      job = application!("Neighbor")
      filed = job.notes.create!(
        tag: :note, occurred_at: 1.hour.ago, source: "Email",
        body: "Hey Rocco, could you send two professional references?"
      )
      email = job_mail!(subject: "Next steps", company: "Neighbor", logged: filed.id)

      run(:add_job_note, {
        company:  "Neighbor",
        note:     "Neighbor asked me to submit two professional references",
        tag:      :availability,
        email_id: email.id,
      })

      expect(filed.reload.body).to eq("Hey Rocco, could you send two professional references?")
      expect(filed.tag).to eq("availability")
      expect(job.notes.count).to eq(1)
    end

    # JobNote#settle_application bails on destroy, so undoing the note alone
    # would take the row away and leave the application marked rejected.
    it "closes the application on a settling tag, and puts the status back on undo", :aggregate_failures do
      application!("Upstart")

      result, = run(:add_job_note, { company: "Upstart", note: "No thanks", tag: :rejected })

      expect(result[:settled]).to be(true)
      expect(JobApplication.find_by(company: "Upstart").status).to eq("rejected")

      result[:reverts].each { |rv| Buddy::Reverter.call(rv) }

      expect(JobNote.count).to be_zero
      expect(JobApplication.find_by(company: "Upstart").status).to eq("active")
    end
  end

  describe ".resolve_application with several jobs at one company" do
    let!(:backend) { user.job_applications.create!(company: "Aledade PBC", role: "Senior Backend Engineer") }
    let!(:manager) { user.job_applications.create!(company: "Aledade PBC", role: "Engineering Manager") }

    # Nil is answerable upstream; a guess is silent and permanent.
    it "picks the one whose role the text names, and is nil rather than a guess", :aggregate_failures do
      solo = user.job_applications.create!(company: "Pellworth", role: "Staff Engineer")

      expect(Buddy::JobHunt.resolve_application(user, "Pellworth")).to eq(solo)
      expect(Buddy::JobHunt.resolve_application(user, "Aledade", said: "Senior Backend Engineer")).to eq(backend)
      expect(Buddy::JobHunt.resolve_application(user, "Aledade PBC")).to be_nil
      expect(Buddy::JobHunt.resolve_application(user, "Aledade PBC", said: "Engineer")).to be_nil
      expect(Buddy::JobHunt.applications_for(user, "Aledade PBC")).to contain_exactly(backend, manager)
    end

    # One head word matching two companies is a coin toss; two rows for the
    # SAME company is not.
    it "still refuses a head word that reaches two different companies" do
      user.job_applications.create!(company: "Acme Systems")
      user.job_applications.create!(company: "Acme Robotics")

      expect(Buddy::JobHunt.applications_for(user, "Acme Talent Acquisition")).to be_empty
    end
  end

  # Note bodies and links are what the search box wants, and what a resolution
  # must not read.
  describe ".applications_for reads the company and nothing else" do
    let!(:onboard) { user.job_applications.create!(company: "OnBoard", role: "Senior Engineer") }

    it "does not resolve a company off a note or link that mentions it, until the company is on the board", :aggregate_failures do
      onboard.notes.create!(body: "Sourced from the openai jobs page", tag: :note, occurred_at: Time.current)
      onboard.update!(url: "https://jobs.example.com/openai-partner/role/8")

      expect(Buddy::JobHunt.applications_for(user, "OpenAI")).to be_empty
      expect(Buddy::JobHunt.resolve_application(user, "OpenAI")).to be_nil

      real = user.job_applications.create!(company: "OpenAI", role: "Applied AI Engineer, Codex Core Agent")
      expect(Buddy::JobHunt.applications_for(user, "OpenAI")).to eq([real])
      expect(Buddy::JobHunt.resolve_application(user, "OpenAI")).to eq(real)
    end

    it "still catches a misspelled company" do
      user.job_applications.create!(company: "Netflix", role: "Staff Engineer")

      expect(Buddy::JobHunt.applications_for(user, "Netflx").map(&:company)).to eq(["Netflix"])
    end

    it "takes the exact name over a near miss at a different company, and refuses when nothing is exact", :aggregate_failures do
      github = user.job_applications.create!(company: "GitHub")
      gitlab = user.job_applications.create!(company: "GitLab", role: "Staff Backend Engineer (Ruby)")

      expect(Buddy::JobHunt.applications_for(user, "GitHub")).to eq([github])
      expect(Buddy::JobHunt.resolve_application(user, "GitHub")).to eq(github)
      expect(Buddy::JobHunt.applications_for(user, "GitLab")).to eq([gitlab])
      expect(Buddy::JobHunt.applications_for(user, "Gitlob")).to be_empty
    end

    it "leaves the role doing its own job of picking between rows" do
      user.job_applications.create!(company: "Stripe", role: "Staff Backend Engineer")
      picked = user.job_applications.create!(company: "Stripe", role: "Product Designer")

      expect(Buddy::JobHunt.resolve_application(user, "Stripe", said: "Product Designer")).to eq(picked)
    end
  end

  # The legal entity on the paperwork, the brand on the board, and the vendors
  # a process is handed to are all one employer as far as the timeline goes.
  describe "the other names an employer's mail arrives under" do
    let!(:job) {
      application!("iCapital").tap { |row|
        row.update!(known_as: ["Institutional Capital Network", "Accurate", "accurate.com"])
      }
    }

    it "answers to the legal name and the vendor's address, ahead of fuzzy matching", :aggregate_failures do
      other = application!("Accurate Systems")

      expect(Buddy::JobHunt.resolve_application(user, "Institutional Capital Network, Inc.")).to eq(job)
      expect(Buddy::JobHunt.applications_for(user, "Accurate")).to eq([job])
      expect(Buddy::JobHunt.applications_for(user, "Accurate Systems")).to eq([other])
      expect(Buddy::JobHunt.resolve_by_sender(user, ["infoneeded@accurate.com"])).to eq(job)
      expect(Buddy::JobHunt.resolve_by_sender(user, ["recruiter@stripe.com"])).to be_nil
    end

    # Two applications screened by the same vendor say nothing about which one
    # a mail belongs to, and a beat on the wrong one is worse than none.
    it "picks neither when two rows both claim the sender" do
      application!("Wildcat").update!(known_as: ["accurate.com"])

      expect(Buddy::JobHunt.resolve_by_sender(user, ["infoneeded@accurate.com"])).to be_nil
    end
  end
end
