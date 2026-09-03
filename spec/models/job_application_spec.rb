require "rails_helper"

RSpec.describe JobApplication do
  let(:user) { create(:user) }

  it "gives every application a colour without being asked" do
    job = user.job_applications.create!(company: "Acme")

    expect(job.color).to match(/\A#[0-9a-f]{6}\z/i)
  end

  it "keeps a colour that was chosen" do
    job = user.job_applications.create!(company: "Acme", color: "#123456")

    expect(job.color).to eq("#123456")
  end

  it "reads as company and role together" do
    expect(user.job_applications.new(company: "Acme", role: "Staff").label).to eq("Acme — Staff")
    expect(user.job_applications.new(company: "Acme").label).to eq("Acme")
  end

  it "falls back to initials when there is no logo" do
    expect(user.job_applications.new(company: "Acme").initials).to eq("A")
    expect(user.job_applications.new(company: "Big Corp").initials).to eq("BC")
  end

  # The column takes any icon reference the shared IconPool speaks, which is
  # the same set a chore's icon holds. Shape isn't validated — over-narrowing
  # it is what stopped an emoji going in — only size, for the one shape that
  # can run away with itself.
  it "takes every shape an icon reference comes in" do
    %w[🏢 ti-building hicon:12 data:image/png;base64,AAAA].each do |ref|
      job = user.job_applications.new(company: "Acme", logo: ref)

      expect(job).to be_valid, "expected #{ref} to be allowed"
    end
  end

  it "refuses a logo bigger than the ceiling" do
    job = user.job_applications.new(company: "Acme", logo: "d" * (JobApplication::MAX_LOGO_BYTES + 1))

    expect(job).not_to be_valid
    expect(job.errors[:logo]).to be_present
  end

  describe "the live scope" do
    it "is everything that hasn't ended" do
      active   = user.job_applications.create!(company: "A", status: :active)
      offer    = user.job_applications.create!(company: "B", status: :offer)
      user.job_applications.create!(company: "C", status: :rejected)
      user.job_applications.create!(company: "D", status: :closed)

      expect(user.job_applications.live.pluck(:id)).to contain_exactly(active.id, offer.id)
    end
  end

  describe "touch_activity!" do
    it "tracks the newest note's own timestamp, not when it was typed" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Applied", occurred_at: 10.days.ago)
      job.notes.create!(body: "Call", occurred_at: 2.days.ago)

      job.touch_activity!

      expect(job.reload.last_activity_at).to be_within(5.seconds).of(2.days.ago)
    end
  end
end
