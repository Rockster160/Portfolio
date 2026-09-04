require "rails_helper"

RSpec.describe "Interview tracker", type: :request do
  let(:user) { create(:user) }
  let(:tiny_png) {
    "data:image/png;base64," \
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
  }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  # The order of the wall, by application id.
  def card_order
    response.body.scan(/<a class="interview-card[^>]*href="\/interviews\/(\d+)"/).flatten.map(&:to_i)
  end

  describe "GET /interviews" do
    let!(:live) { user.job_applications.create!(company: "Acme") }
    let!(:dead) { user.job_applications.create!(company: "Initech", status: :rejected) }

    it "hides the rejected ones by default" do
      get interviews_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Acme")
      expect(response.body).not_to include("Initech")
    end

    it "shows everything when asked" do
      get interviews_path(status: :all)

      expect(response.body).to include("Acme")
      expect(response.body).to include("Initech")
    end

    it "filters to a single status" do
      get interviews_path(status: :rejected)

      expect(response.body).to include("Initech")
      # Acme still appears in the capture form's dropdown; what the filter
      # decides is which cards are on the wall.
      expect(response.body).not_to include("href=\"#{interview_path(live)}\"")
    end

    # The picker is the same partial as the job page; on the form it has no
    # record to PATCH, so it posts the square in a hidden field instead.
    it "offers the icon square on the new-company form" do
      get interviews_path

      expect(response.body).to include("data-icon-stack")
      expect(response.body).to include(%(name="job_application[logo]"))
      # No record to save to yet, so it posts with the form rather than
      # PATCHing on change.
      expect(response.body).not_to include("data-logo-url=")
    end

    # The chip already says APPLIED. A bodyless note used to print its own
    # label underneath as a sentence, so the card said it twice.
    it "says a tag once on a card whose note has no body" do
      job = user.job_applications.create!(company: "Samsara")
      job.notes.create!(tag: :applied, occurred_at: 1.day.ago)

      get interviews_path

      card = response.body[/<a class="interview-card[^>]*href="#{interview_path(job)}".*?<\/a>/m]
      text = ActionController::Base.helpers.strip_tags(card).gsub(/\s+/, " ")
      expect(text.scan(/Applied/i).size).to eq(1)
    end

    # The wall is sorted by "what touched this most recently", which will
    # happily bury Thursday's interview under an email sent this morning.
    it "lifts a booked interview to the front of the wall" do
      stale = user.job_applications.create!(company: "Booked")
      stale.notes.create!(
        tag: :scheduled, occurred_at: 20.days.ago,
        follow_up_at: 4.days.from_now
      )
      stale.touch_activity!
      fresh = user.job_applications.create!(company: "Busy")
      fresh.notes.create!(body: "Emailed them", occurred_at: 1.minute.ago)
      fresh.touch_activity!

      get interviews_path

      expect(card_order.first).to eq(stale.id)
      expect(card_order).to include(fresh.id)
    end

    it "sorts two booked interviews by which comes first" do
      friday = user.job_applications.create!(company: "Friday")
      friday.notes.create!(tag: :scheduled, follow_up_at: 5.days.from_now)
      tuesday = user.job_applications.create!(company: "Tuesday")
      tuesday.notes.create!(tag: :scheduled, follow_up_at: 2.days.from_now)

      get interviews_path

      expect(card_order.first(2)).to eq([tuesday.id, friday.id])
    end

    # An interview you attend and a message you owe are different obligations,
    # and running them into one list is what made this fiddly.
    it "keeps interviews out of the follow-ups strip" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :scheduled, follow_up_at: 2.days.from_now)

      get interviews_path

      expect(response.body).to include("Interviews booked")
      expect(response.body).not_to include("Following up")
    end

    it "drops an interview that has already happened off both strips" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :scheduled, occurred_at: 10.days.ago, follow_up_at: 2.days.ago)

      get interviews_path

      expect(response.body).not_to include("Interviews booked")
      expect(response.body).not_to include("Following up")
    end

    # "Sep 7" needs a calendar lookup before it means anything.
    it "names the weekday on a date you have to plan around" do
      job = user.job_applications.create!(company: "Acme")
      at = 3.days.from_now.change(hour: 14, min: 0)
      job.notes.create!(tag: :scheduled, follow_up_at: at)

      get interviews_path

      # Rendered in the reader's zone — the controller wraps every request in it.
      shown = at.in_time_zone(user.timezone).strftime("%A, %b %-d at %-I:%M %p")
      expect(response.body).to include(shown)
    end

    it "never shows someone else's applications" do
      create(:user).job_applications.create!(company: "SomeoneElseCo")

      get interviews_path(status: :all)

      expect(response.body).not_to include("SomeoneElseCo")
    end
  end

  describe "GET /interviews?q=" do
    let!(:netflix) { user.job_applications.create!(company: "Netflix") }
    let!(:anrok) { user.job_applications.create!(company: "Anrok") }

    it "narrows the wall to what matches" do
      get interviews_path(q: "netflix")

      expect(card_order).to eq([netflix.id])
      expect(response.body).to include("1 match")
    end

    it "ranks the company above one that only mentions it in a note" do
      anrok.notes.create!(tag: :note, body: "Recruiter came from Netflix.", occurred_at: 1.hour.ago)
      anrok.touch_activity!
      netflix.notes.create!(tag: :applied, occurred_at: 20.days.ago)
      netflix.touch_activity!

      get interviews_path(q: "netflix")

      expect(card_order).to eq([netflix.id, anrok.id])
    end

    it "forgives a typo" do
      get interviews_path(q: "netflx")

      expect(card_order).to eq([netflix.id])
    end

    # The chips narrow, the query ranks, and clicking either keeps the other.
    it "carries the query onto the status chips" do
      get interviews_path(q: "netflix")

      expect(response.body).to include(CGI.escapeHTML(interviews_path(status: :all, q: "netflix")))
    end

    it "searches inside the chosen status only" do
      user.job_applications.create!(company: "Netflix Games", status: :rejected)

      get interviews_path(q: "netflix")
      expect(card_order).to eq([netflix.id])

      get interviews_path(q: "netflix", status: :all)
      expect(card_order.size).to eq(2)
    end

    it "offers the wider search when a narrowed one finds nothing" do
      user.job_applications.create!(company: "Zillow", status: :rejected)

      get interviews_path(q: "zillow")

      expect(response.body).to include("Nothing matches")
      expect(response.body).to include(CGI.escapeHTML(interviews_path(q: "zillow", status: :all)))
    end

    it "shows everything again once the query is cleared" do
      get interviews_path(q: "")

      expect(card_order).to contain_exactly(netflix.id, anrok.id)
    end
  end

  describe "POST /interviews" do
    it "creates the application and its first note together" do
      post interviews_path, params: {
        job_application: { company: "Acme", role: "Staff", source: "LinkedIn", url: "https://acme.test/jobs/1" },
        job_note:        { body: "Applied through their site.", tag: :applied },
      }

      job = user.job_applications.last
      expect(job.company).to eq("Acme")
      expect(job.source).to eq("LinkedIn")
      expect(job.notes.map(&:body)).to eq(["Applied through their site."])
      expect(job.reload.last_activity_at).to be_present
      expect(response).to redirect_to(interview_path(job))
    end

    it "keeps a cropped image from the square" do
      post interviews_path, params: {
        job_application: { company: "Acme", logo: tiny_png },
        job_note:        { body: "Applied." },
      }

      expect(user.job_applications.last.logo).to eq(tiny_png)
    end

    it "keeps an emoji typed into the square" do
      post interviews_path, params: {
        job_application: { company: "Acme", logo: "🏢" },
        job_note:        { body: "Applied." },
      }

      expect(user.job_applications.last.logo).to eq("🏢")
    end

    # Picking a tag IS the note — an application logged on a date needs no
    # sentence under it.
    it "logs a tagged note even with nothing written" do
      post interviews_path, params: {
        job_application: { company: "Acme" },
        job_note:        { body: "", tag: :applied },
      }

      note = user.job_applications.last.notes.sole
      expect(note.tag).to eq("applied")
      expect(note.body).to be_nil
    end

    it "creates an application on its own when no note was written" do
      post interviews_path, params: {
        job_application: { company: "Acme" },
        job_note:        { body: "  ", tag: :note },
      }

      job = user.job_applications.last
      expect(job.company).to eq("Acme")
      expect(job.notes).to be_empty
    end

    # The dropdown half of "pick a job, or name a new one".
    it "adds the note to the chosen application instead of making another" do
      existing = user.job_applications.create!(company: "Acme")

      expect {
        post interviews_path, params: {
          job_application_id: existing.id,
          job_application:    { company: "" },
          job_note:           { body: "Recruiter called.", tag: :recruiter_call },
        }
      }.not_to change(JobApplication, :count)

      expect(existing.notes.map(&:body)).to eq(["Recruiter called."])
    end

    it "does not pick an application belonging to somebody else" do
      theirs = create(:user).job_applications.create!(company: "Theirs")

      post interviews_path, params: {
        job_application_id: theirs.id,
        job_application:    { company: "Mine" },
        job_note:           { body: "Note." },
      }

      expect(theirs.notes).to be_empty
      expect(user.job_applications.last.company).to eq("Mine")
    end

    it "bounces back with the error when the company is blank" do
      post interviews_path, params: { job_application: { company: "" }, job_note: { body: "x" } }

      expect(response).to redirect_to(interviews_path)
      expect(flash[:alert]).to be_present
      expect(user.job_applications).to be_empty
    end
  end

  describe "PATCH /interviews/:id" do
    let(:job) { user.job_applications.create!(company: "Acme") }

    it "updates the status" do
      patch interview_path(job), params: { job_application: { status: :rejected } }

      expect(job.reload.status).to eq("rejected")
    end

    # The square PATCHes on change rather than waiting for a submit, so every
    # shape it can hold arrives this way.
    it "stores whatever the square was set to" do
      { image: tiny_png, emoji: "🏢", tabler: "ti-building", custom: "hicon:12" }.each_value { |ref|
        patch interview_path(job),
          params:  { job_application: { logo: ref } }.to_json,
          headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

        expect(response).to have_http_status(:ok)
        expect(job.reload.logo).to eq(ref)
      }
    end

    it "422s on a logo past the ceiling" do
      patch interview_path(job),
        params:  { job_application: { logo: "d" * (JobApplication::MAX_LOGO_BYTES + 1) } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(job.reload.logo).to be_nil
    end

    it "clears the logo when the square is emptied" do
      job.update!(logo: tiny_png)

      patch interview_path(job),
        params:  { job_application: { logo: "" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

      expect(job.reload.logo).to be_nil
    end
  end

  describe "notes" do
    let(:job) { user.job_applications.create!(company: "Acme") }

    it "adds one" do
      post interview_notes_path(job), params: {
        job_note: { body: "Phone screen went well.", tag: :interview, spoke_to: "Dana", duration_minutes: 30 },
      }

      note = job.notes.last
      expect(note.body).to eq("Phone screen went well.")
      expect(note.spoke_to).to eq("Dana")
      expect(note.duration_minutes).to eq(30)
      expect(response).to redirect_to(interview_path(job))
    end

    it "clears a follow-up when the field comes back empty" do
      note = job.notes.create!(body: "Chase", follow_up_at: 2.days.from_now)
      expect(note.reload.agenda_item_id).to be_present

      patch interview_note_path(job, note), params: { job_note: { body: "Chase", follow_up_at: "" } }

      expect(note.reload.follow_up_at).to be_nil
      expect(note.agenda_item_id).to be_nil
    end

    it "deletes one" do
      note = job.notes.create!(body: "Oops")

      delete interview_note_path(job, note)

      expect(job.notes.reload).to be_empty
    end

    # The lookup goes through the current user's applications, so an id from
    # someone else's search never resolves. ApplicationController turns the
    # RecordNotFound into a bounce to login.
    it "writes nothing for a note on somebody else's application" do
      theirs = create(:user).job_applications.create!(company: "Theirs")

      post interview_notes_path(theirs), params: { job_note: { body: "hi" } }

      expect(theirs.notes.reload).to be_empty
      expect(response).to have_http_status(:redirect)
    end
  end

  describe "GET /interviews/:id" do
    # Every note carries the same fieldset, so without a per-note id namespace
    # the page ships a dozen inputs called `job_note_body` and each label
    # focuses whichever one the browser reached first.
    it "gives every field on the page its own id" do
      job = user.job_applications.create!(company: "Acme")
      2.times { |i| job.notes.create!(body: "Note #{i}") }

      get interview_path(job)

      ids = response.body.scan(/\bid="([^"]+)"/).flatten
      expect(ids.tally.select { |_id, count| count > 1 }).to be_empty
    end

    # Here the picker DOES have a record behind it, so it saves on its own.
    it "puts the square in the title, wired to save immediately" do
      job = user.job_applications.create!(company: "Acme", logo: "🏢")

      get interview_path(job)

      expect(response.body).to include(%(data-logo-url="#{interview_path(job)}"))
      expect(response.body).to include("data-icon-stack")
      # Rendered server-side too, so an existing mark is there on first paint
      # rather than appearing once the pool loads.
      expect(response.body).to include(%(<span class="icon-glyph">🏢</span>))
    end

    # It is the only way back to the wall — this app has no global nav — and it
    # spent a while under the timeline, where a job with twenty notes hid it
    # entirely.
    it "puts the way back above the card, not under the timeline" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Applied")

      get interview_path(job)

      back = response.body.index("All applications")
      expect(back).to be < response.body.index("app-card-container")
    end

    # Where the application stands is the last thing that happened, so it goes
    # at the top rather than at the end of a long scroll.
    it "shows the newest note first" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Older thing", occurred_at: 9.days.ago)
      job.notes.create!(body: "Newer thing", occurred_at: 1.day.ago)

      get interview_path(job)

      expect(response).to have_http_status(:ok)
      expect(response.body.index("Newer thing")).to be < response.body.index("Older thing")
    end

    # You open this page because something just happened. Writing comes first,
    # and what you write lands directly beneath the form.
    it "puts the add-note form above the timeline" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Something happened")

      get interview_path(job)

      expect(response.body.index("+ Add a note")).to be < response.body.index("Timeline")
    end
  end
end
