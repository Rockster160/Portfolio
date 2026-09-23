require "rails_helper"

RSpec.describe "add_job_application tool" do
  let(:user) { create(:user) }
  let(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:ctx) { Buddy::ToolContext.new(user, conversation: conversation) }
  let(:tool) { Buddy::Tools[:add_job_application] }

  def confirm(**payload)
    tool[:confirm].call({ company: "Pellworth Dynamics" }.merge(payload), ctx)
  end

  def execute(**payload)
    tool[:execute].call(confirm(**payload)[:resolved], ctx)
  end

  # It waits to be tapped rather than arriving pre-checked: a whole new row on
  # the board is more than a beat on one.
  it "is a level 3 proposal" do
    expect(tool[:level]).to eq(3)
  end

  it "creates the row with its first beat, timestamped when the mail came in" do
    arrived = 2.days.ago.change(usec: 0)

    result = execute(
      role: "Staff Engineer", note: "Recruiter reached out.",
      tag: :heard_back, occurred_at: arrived, source: "LinkedIn"
    )

    job = user.job_applications.find_by(company: "Pellworth Dynamics")
    expect(job.role).to eq("Staff Engineer")
    expect(job.notes.count).to eq(1)
    expect(job.notes.first.tag).to eq("heard_back")
    expect(job.notes.first.occurred_at).to be_within(1.second).of(arrived)
    expect(result[:url]).to end_with("/interviews/#{job.id}")
  end

  # A second row for the SAME job splits its timeline, and nothing downstream
  # would ever put them back together. The description says so; this enforces it.
  it "refuses a company that is already on the board with nothing to tell them apart" do
    user.job_applications.create!(company: "Pellworth Dynamics, Inc.")

    expect { confirm(note: "They wrote again.") }.to raise_error(/already on the board/)
  end

  # Three jobs at one place is three rows with three separate outcomes. This is
  # the case the tool exists for, and it was refused outright until now.
  describe "a second role at a company already on the board" do
    let!(:first) {
      user.job_applications.create!(company: "Pellworth Dynamics", role: "Principal Engineer")
    }

    it "opens a row of its own" do
      execute(role: "Staff Frontend Engineer", tag: :applied, note: "Applied.")

      roles = user.job_applications.where(company: "Pellworth Dynamics").pluck(:role)
      expect(roles).to contain_exactly("Principal Engineer", "Staff Frontend Engineer")
    end

    it "still refuses the same job twice" do
      expect { confirm(role: "Principal Engineer", note: "Applied again.") }
        .to raise_error(/already on the board - use add_job_note/)
    end

    # Half the board carries no role at all, so this is the ordinary shape
    # rather than an edge — and with nothing to tell the two apart, a guess
    # would be a duplicate nobody could later separate.
    it "refuses when the row already there has no role recorded" do
      first.update!(role: nil)

      expect { confirm(role: "Staff Frontend Engineer", note: "Applied.") }
        .to raise_error(/no role recorded/)
    end

    it "refuses when this one brings no role either" do
      expect { confirm(note: "Applied.") }.to raise_error(/pass its `role`/)
    end
  end

  # The card is offered against the board as it was, and tapped against the
  # board as it is. JPMorgan and Epicor each got two rows seconds apart when
  # jobhunt wrote the row in between.
  describe "a row that appeared between the offer and the tap" do
    it "lands a role-bearing card on the row for that role" do
      resolved = confirm(role: "Staff Engineer", tag: :acknowledged)[:resolved]
      row      = user.job_applications.create!(company: "Pellworth Dynamics", role: "Staff Engineer")

      result = tool[:execute].call(resolved, ctx)

      expect(result[:joined]).to be(true)
      expect(user.job_applications.count).to eq(1)
      expect(row.notes.pluck(:tag)).to eq(["acknowledged"])
    end

    # Prod 6391: JPMorgan's verification code, offered with no role a minute
    # before jobhunt made row 36.
    it "lands a role-less card on the one row now there" do
      resolved = confirm(note: "A code to confirm who they are.")[:resolved]
      row      = user.job_applications.create!(company: "Pellworth Dynamics", role: "Staff Engineer")

      result = tool[:execute].call(resolved, ctx)

      expect(result[:joined]).to be(true)
      expect(user.job_applications.count).to eq(1)
      expect(row.notes.count).to eq(1)
    end

    it "refuses a role-less card when there are several to choose from" do
      resolved = confirm(note: "A code to confirm who they are.")[:resolved]
      user.job_applications.create!(company: "Pellworth Dynamics", role: "Staff Engineer")
      user.job_applications.create!(company: "Pellworth Dynamics", role: "Principal Engineer")

      expect { tool[:execute].call(resolved, ctx) }.to raise_error(/2 applications on the board now/)
      expect(user.job_applications.count).to eq(2)
    end
  end

  it "refuses an untagged note with nothing in it" do
    expect { confirm(note: "  ") }.to raise_error(/nothing to log/)
  end

  # A tagged beat is a whole fact without a sentence beside it.
  it "takes a tag with no words" do
    execute(tag: :applied, note: "")

    expect(user.job_applications.first.notes.first.tag).to eq("applied")
  end

  it "makes the row alone when there is no beat yet" do
    execute(tag: :note, note: "Saw the listing.")

    expect(user.job_applications.first.notes.count).to eq(1)
  end

  # The note rides on `dependent: :destroy`, so undo leaves nothing half-made.
  it "undoes to nothing at all" do
    result = execute(note: "Recruiter reached out.", tag: :heard_back)
    revert = result[:reverts].first

    expect(revert).to include(op: "created", model: "JobApplication")
    expect(Buddy::Reverter.reversible?(revert)).to be(true)

    Buddy::Reverter.call(revert)
    expect(user.job_applications.count).to be_zero
    expect(JobNote.count).to be_zero
  end

  it "links the row it made" do
    result = execute(note: "Recruiter reached out.", tag: :heard_back)

    expect(tool[:receipt].call(result, ctx)).to include("[Pellworth Dynamics](")
  end

  # The other half of the job-mail path: mail from a company NOT on the board
  # opens the row here rather than filing a beat, and it is no less an email for
  # that. Same question, same answer as add_job_note.
  describe "the mail behind the card" do
    let(:email) {
      user.emails.create!(
        direction: :inbound,
        mail_id:   "pell-1@greenhouse.test",
        subject:   "Thanks for applying",
        blurb:     "We got it.",
        timestamp: 3.hours.ago.change(usec: 0),
      )
    }

    it "offers the email to read before the tap" do
      words = tool[:hint].call({ company: "Pellworth Dynamics", email_id: email.id }, ctx)

      expect(words["tap"]).to include("/emails/#{email.id}")
    end

    it "stamps the first beat with the mail's own clock and a link back" do
      execute(email_id: email.id, tag: :acknowledged, note: "We got it.")
      note = user.job_applications.find_by(company: "Pellworth Dynamics").notes.first

      expect(note.occurred_at).to eq(email.timestamp)
      expect(note.source).to eq("Email")
      expect(note.url).to include("/emails/#{email.id}")
    end

    # Without this the same mail keeps reading as outstanding and gets offered
    # again every time the board is looked at.
    it "files the mail against the beat it made" do
      execute(email_id: email.id, tag: :acknowledged, note: "We got it.")
      note = user.job_applications.find_by(company: "Pellworth Dynamics").notes.first

      expect(email.reload.job_triage[:job_note_id]).to eq(note.id)
    end

    it "marks Ardesian's copy read and archived, and labels the real one" do
      expect(LabelMailWorker).to receive(:perform_async).with(email.id)

      execute(email_id: email.id, tag: :acknowledged, note: "We got it.")
      email.reload

      expect(email).to be_read
      expect(email).to be_archived
    end

    it "puts the mail back when the row is unticked" do
      result = execute(email_id: email.id, tag: :acknowledged, note: "We got it.")
      mail_revert = result[:reverts].find { |r| r[:model] == "Email" }

      expect(mail_revert[:before]).to eq({ "read_at" => nil, "archived_at" => nil })
    end
  end
end
