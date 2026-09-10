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

  # Two rows for one company splits its timeline, and nothing downstream would
  # ever put them back together. The description says so; this enforces it.
  it "refuses a company that is already on the board" do
    user.job_applications.create!(company: "Pellworth Dynamics, Inc.")

    expect { confirm(note: "They wrote again.") }.to raise_error(/already on the board/)
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
end
