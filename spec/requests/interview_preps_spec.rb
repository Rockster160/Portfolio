require "rails_helper"

# Reading the brief. It arrives as a link in a push an hour before the
# interview, so the page it opens is the whole of what this is for.
RSpec.describe "Interview prep", type: :request do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Bluestaq", role: "Principal Engineer") }
  let(:prep) {
    job.preps.create!(
      title:        "Technical screen with Bluestaq",
      kind:         "technical",
      interview_at: 1.hour.from_now,
      body:         <<~MD,
        ## The company
        They build data platforms for the Space Force.

        ## What to go over
        - Ruby's Enumerable, **lazy** especially

        > Walk me through how you would shard this.
      MD
    )
  }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    post(login_path, params: { user: { username: user.username, password: "password123" } })
  end

  it "opens on the brief itself" do
    get interview_prep_path(job, prep)

    expect(response.body).to include("Technical screen with Bluestaq")
    expect(response.body).to include("They build data platforms for the Space Force.")
  end

  # The markdown is the brief's structure - it is read by skimming headings
  # with ten minutes to go - so it has to arrive as headings.
  it "renders what the session wrote as markdown" do
    get interview_prep_path(job, prep)

    expect(response.body).to include("<h2>What to go over</h2>")
    expect(response.body).to include("<strong>lazy</strong>")
    expect(response.body).to include("<blockquote>")
  end

  it "says what kind of conversation it is written for" do
    get interview_prep_path(job, prep)

    expect(response.body).to include("Technical interview")
  end

  it "is reachable from the application's own page afterwards" do
    where = interview_prep_path(job, prep)

    get interview_path(job)

    expect(response.body).to include(where)
  end

  it "is nobody else's to read" do
    other = create(:user).job_applications.create!(company: "Elsewhere")
    stolen = other.preps.create!(body: "not yours")

    get interview_prep_path(other, stolen)

    expect(response.body).not_to include("not yours")
  end

  it "can be thrown away when it says something wrong" do
    delete interview_prep_path(job, prep)

    expect(response).to redirect_to(interview_path(job))
    expect(job.preps.reload).to be_empty
  end
end
