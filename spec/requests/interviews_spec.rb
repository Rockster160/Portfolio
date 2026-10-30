require "rails_helper"

RSpec.describe "Interview tracker", type: :request do
  let(:user) { create(:user) }
  let(:tiny_png) {
    "data:image/png;base64," \
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
  }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  # The number printed on one status chip, by its label.
  def chip_count(label)
    pattern = /#{label}\s*<span class="chip-count">(\d+)<\/span>/
    response.body[pattern, 1]&.to_i
  end

  # The ids in the JSON the local job hunter reads.
  def json_ids
    response.parsed_body["jobs"].map { |job| job["id"] }
  end

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
    # The Type dropdown is ordered by when a beat happens, so its first option
    # is no longer a safe default - a blank body under any other tag is a beat
    # this form would file.
    it "opens the capture form's Type on Note" do
      get interviews_path

      form = response.body[/<form[^>]*capture-form.*?<\/form>/m]
      block = form[/<select[^>]*name="job_note\[tag\]".*?<\/select>/m]
      expect(block[/<option selected="selected" value="(\w+)"/, 1]).to eq("note")
    end

    # Reading down a process, each option saying who causes it.
    it "says who causes each kind of beat" do
      get interviews_path

      expect(response.body).to include("Applied — you")
      expect(response.body).to include("Acknowledged — a machine")
      expect(response.body).to include("Heard back — them")
    end

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

    # What the job IS, as against where it has got to - the pair being compared
    # across the wall rather than read off one row.
    it "prints the pay, the location and the vibe on a card" do
      job = user.job_applications.create!(
        company:  "Samsara",
        location: "Remote",
        pay:      "160-170 + commissions",
      )
      job.notes.create!(tag: :interview, occurred_at: 1.day.ago, did_well: 7, liked_them: 9)

      get interviews_path

      card = response.body[/<a class="interview-card[^>]*href="#{interview_path(job)}".*?<\/a>/m]
      expect(card).to include("160-170 + commissions")
      expect(card).to include("Remote")
      expect(card).to include("Did 7.0")
      expect(card).to include("Liked 9.0")
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

    it "holds an interview that has happened until something is written about it" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :scheduled, occurred_at: 10.days.ago, follow_up_at: 2.days.ago)

      get interviews_path

      expect(response.body).to include("Interviews booked")
      expect(response.body).to include("how did it go?")
      expect(response.body).not_to include("Following up")
    end

    it "lets it go once a beat lands after it" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :scheduled, occurred_at: 10.days.ago, follow_up_at: 2.days.ago)
      job.notes.create!(tag: :note, body: "Went well", occurred_at: 1.day.ago)

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

  # Everything above the fold read `follow_up_at`, so an availability request -
  # which arrives as a task with no date on it - appeared in neither strip and
  # sat on the wall as an ordinary note between two things the company did.
  # Nine tenths of a job search is applied, receipted by a machine, never
  # answered by anybody - and each one held a square on the wall.
  describe "the stale drop-off" do
    # Went in, got receipted, nothing since.
    def quiet_row(company, applied_at)
      job = user.job_applications.create!(company: company)
      job.notes.create!(tag: :applied, occurred_at: applied_at)
      job
    end

    it "drops one nobody has answered in over a week" do
      job = quiet_row("Initech", 8.days.ago)

      get interviews_path

      expect(card_order).not_to include(job.id)
      expect(chip_count("Stale")).to eq(1)
      expect(chip_count("Live")).to eq(0)
    end

    it "keeps one that went in this week" do
      job = quiet_row("Initech", 3.days.ago)

      get interviews_path

      expect(card_order).to include(job.id)
      expect(chip_count("Stale")).to eq(0)
      expect(chip_count("Live")).to eq(1)
    end

    # The week runs from the last thing TRACKED, not from the application: an
    # ATS re-sending its own template is still something having happened.
    it "counts the week from the last beat on the row" do
      job = quiet_row("Initech", 20.days.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 2.days.ago)

      get interviews_path

      expect(card_order).to include(job.id)
    end

    # Somebody answered. However long ago that was, this is not the shape the
    # drop-off is for - marking it Ghosted is his call to make.
    it "keeps one a person has answered, however quiet it has gone" do
      job = user.job_applications.create!(company: "Initech")
      job.notes.create!(tag: :heard_back, occurred_at: 30.days.ago, body: "Keen to talk")

      get interviews_path

      expect(card_order).to include(job.id)
      expect(chip_count("Stale")).to eq(0)
    end

    it "opens the pile on its own chip" do
      job = quiet_row("Initech", 8.days.ago)

      get interviews_path(status: :stale)

      expect(card_order).to eq([job.id])
    end

    # Typing a company is asking where it is, and having gone quiet is the
    # likeliest reason to go looking.
    it "still turns up in a search of the live board" do
      job = quiet_row("Initech", 8.days.ago)

      get interviews_path(q: "Initech")

      expect(card_order).to eq([job.id])
    end

    # The local job hunter asks this so it never applies to the same company
    # twice. A row it cannot see is a company it applies to again.
    it "stays in the JSON the local job hunter reads" do
      job = quiet_row("Initech", 8.days.ago)

      get interviews_path(format: :json)

      expect(json_ids).to include(job.id)
    end

    # A beat landing on a quiet row is what brings it back, so the picker it is
    # logged from has to still offer it.
    it "stays in the picker on the capture form" do
      quiet_row("Initech", 8.days.ago)

      get interviews_path

      expect(response.body).to include(">Initech<")
    end
  end

  # The hand-marked twin: somebody answered, and then stopped. No clock can
  # tell that from a company that is simply slow, so this one is his to say.
  describe "a ghosted application" do
    let(:job) {
      job = user.job_applications.create!(company: "Initech")
      job.notes.create!(tag: :heard_back, occurred_at: 30.days.ago, body: "Keen to talk")
      job.touch_activity!
      job
    }

    it "leaves the wall and counts on its own chip" do
      patch interview_path(job), params: { job_application: { status: :ghosted } }

      get interviews_path

      expect(card_order).not_to include(job.id)
      expect(chip_count("Ghosted")).to eq(1)
      expect(chip_count("Live")).to eq(0)
    end

    # The whole point of marking it by hand: it is marked weeks after the
    # silence started, and the row still dates from the last beat.
    it "reads its age from the last beat, not from being marked" do
      patch interview_path(job), params: { job_application: { status: :ghosted } }

      get interviews_path(status: :ghosted)

      expect(card_order).to eq([job.id])
      expect(response.body).to include("1 month ago")
      expect(response.body).not_to include("less than a minute ago")
    end

    it "is not counted as stale as well" do
      quiet = user.job_applications.create!(company: "Acme")
      quiet.notes.create!(tag: :applied, occurred_at: 20.days.ago)
      patch interview_path(quiet), params: { job_application: { status: :ghosted } }

      get interviews_path

      expect(chip_count("Stale")).to eq(0)
      expect(chip_count("Ghosted")).to eq(1)
    end
  end

  # A recruiter came to him about something he does not want. The row had been
  # asking him to answer a message he had decided not to answer.
  # THE PROCESS: how far along this one is, which a timeline read bottom-up is
  # worst at answering.
  describe "the other names an application answers to" do
    let!(:job) { user.job_applications.create!(company: "iCapital") }

    it "offers the field on the page" do
      get interview_path(job)

      expect(response.body).to include("Also known as")
    end

    it "saves what was typed into it" do
      patch interview_path(job),
        params: { job_application: { known_as_lines: "Institutional Capital Network\naccurate.com" } }

      expect(job.reload.known_as).to eq(["Institutional Capital Network", "accurate.com"])
    end
  end

  describe "the rubric on an application" do
    let!(:job) { user.job_applications.create!(company: "Acme") }

    # The strip of the page the panel occupies, so a step name is not matched
    # against the whole document.
    def rubric_strip
      response.body[/<div class="job-rubric">.*?<details/m].to_s
    end

    it "opens on the standard steps" do
      get interview_path(job)

      expect(rubric_strip).to include("Applied", "Recruiter screen", "Onsite loop", "Offer")
      expect(rubric_strip).to include("0 of 6")
    end

    # Every form in this app is a card unless it says otherwise - shadow, fill
    # and all - and a card inside this panel's own box clipped the heading
    # against its edge.
    it "draws no second card inside the panel" do
      get interview_path(job)

      expect(rubric_strip.scan(/<form[^>]*>/).size).to eq(1)
      expect(rubric_strip).to include('class="basic"')
    end

    it "shows the ones the timeline has answered as answered" do
      job.notes.create!(tag: :applied, occurred_at: 2.weeks.ago)
      get interview_path(job)

      expect(rubric_strip).to include("1 of 6")
    end

    it "takes the company's own rounds" do
      patch rubric_interview_path(job), params: { rubric: { lines: "Team call\nLive coding\nCEO" } }

      expect(response).to redirect_to(interview_path(job))
      expect(job.reload.rubric.pluck("name")).to eq(["Team call", "Live coding", "CEO"])
    end

    it "ticks a step by hand" do
      patch rubric_interview_path(job), params: { rubric: { ticking: 1, done: ["1"] } }

      expect(job.reload.rubric_steps.map(&:done?)).to eq([false, true, false, false, false, false])
    end

    it "clears a hand tick when the box comes back unchecked" do
      patch rubric_interview_path(job), params: { rubric: { ticking: 1, done: ["1"] } }
      patch rubric_interview_path(job), params: { rubric: { ticking: 1 } }

      expect(job.reload.rubric_steps).to all(satisfy { |step| !step.done? })
    end

    # Without the marker, a save with nothing ticked and a request with no
    # rubric in it at all look identical.
    it "leaves the ticks alone when the request carries none" do
      patch rubric_interview_path(job), params: { rubric: { ticking: 1, done: ["0"] } }
      patch rubric_interview_path(job), params: {}

      expect(job.reload.rubric_steps.first.done?).to be(true)
    end
  end

  describe "ignoring an approach" do
    let(:job) {
      job = user.job_applications.create!(company: "Initech")
      job.notes.create!(tag: :reached_out, occurred_at: 2.days.ago, body: "Got a role for you")
      job.touch_activity!
      job
    }

    it "stops asking him to reply, and leaves the wall" do
      post interview_notes_path(job), params: { job_note: { tag: :ignored, occurred_at: Time.current } }

      get interviews_path

      expect(job.reload.status).to eq("ignored")
      expect(card_order).not_to include(job.id)
      expect(response.body).not_to include("Reply to them")
      expect(chip_count("Ignored")).to eq(1)
    end

    it "opens on its own chip" do
      post interview_notes_path(job), params: { job_note: { tag: :ignored, occurred_at: Time.current } }

      get interviews_path(status: :ignored)

      expect(card_order).to eq([job.id])
    end
  end

  describe "the waiting-on-you strip" do
    let!(:job) { user.job_applications.create!(company: "Neighbor") }

    # The markup of one row of the strip, by what is owed.
    def waiting_row(owed)
      response.body[/<span class="waiting-what">#{owed}<\/span>(.{0,300}?)<\/li>/m, 1]
    end

    it "shows an availability request with no date on it at all" do
      job.notes.create!(tag: :availability, body: "Pick a slot", occurred_at: 2.days.ago)

      get interviews_path

      expect(response.body).to include("Waiting on you")
      expect(waiting_row("Send availability")).to include("Neighbor")
      expect(waiting_row("Send availability")).to include("2 days")
    end

    it "links the mail when the note carries one" do
      job.notes.create!(tag: :availability, url: "https://ardesian.com/emails/51803")

      get interviews_path

      expect(waiting_row("Send availability")).to include("https://ardesian.com/emails/51803")
    end

    it "says nothing once the beat it was waiting on is answered" do
      job.notes.create!(tag: :availability, occurred_at: 2.days.ago)
      job.notes.create!(tag: :scheduled, follow_up_at: 3.days.from_now)

      get interviews_path

      expect(response.body).not_to include("Waiting on you")
      expect(response.body).to include("Interviews booked")
    end

    it "reads the LAST beat, not any beat" do
      job.notes.create!(tag: :heard_back, body: "Luke wrote", occurred_at: 3.days.ago)
      job.notes.create!(tag: :responded, body: "Wrote back", occurred_at: 2.days.ago)

      get interviews_path

      expect(response.body).not_to include("Waiting on you")
    end

    it "leaves a dead application out of it" do
      job.update!(status: :rejected)
      job.notes.create!(tag: :take_home, body: "Build a thing")

      get interviews_path

      expect(response.body).not_to include("Waiting on you")
    end

    # Longest-waiting first: the one being ignored is the one worth printing at
    # the top, and newest-first buries exactly that.
    it "puts the oldest at the top" do
      other = user.job_applications.create!(company: "Halloway")
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago)
      other.notes.create!(tag: :take_home, body: "Build a thing", occurred_at: 9.days.ago)

      get interviews_path

      expect(response.body.index("Take-home to do")).to be < response.body.index("Send availability")
    end

    # One obligation, printed once. A dated availability note is in both lists.
    it "keeps the dated one out of the chase list" do
      job.notes.create!(tag: :availability, body: "Pick a slot", follow_up_at: 1.day.from_now)

      get interviews_path

      expect(response.body).to include("Waiting on you")
      expect(response.body).not_to include("Following up")
    end
  end

  # Most of the board is rows nobody ever answered. This is the handful where a
  # person on their side has moved, how far each one got and how much was said.
  describe "the where-you-stand table" do
    let!(:job) { user.job_applications.create!(company: "Reserv", role: "Senior Engineer") }

    # One whole row of the table, by the stage it reports.
    def standing_row(stage)
      rows = response.body.scan(/<tbody>(.*?)<\/tbody>/m).flatten.first.to_s
      rows.scan(/<tr>(.*?)<\/tr>/m).flatten.find { |row| row.include?(">#{stage}<") }
    end

    # Every cell of every row, in order, whitespace flattened.
    def standing_cells
      body = response.body.scan(/<tbody>(.*?)<\/tbody>/m).flatten.first.to_s
      body.scan(/<tr>(.*?)<\/tr>/m).flatten.map { |row|
        row.scan(/<td[^>]*>(.*?)<\/td>/m).flatten.map { |cell| cell.gsub(/<[^>]+>/, "").strip }
      }
    end

    it "says nothing about a board nobody has answered" do
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 2.days.ago)

      get interviews_path

      expect(response.body).not_to include("Where you stand")
    end

    it "prints the stage reached, the round trips, the company and the days quiet" do
      job.notes.create!(tag: :applied, occurred_at: 5.days.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 5.days.ago)
      job.notes.create!(tag: :take_home, occurred_at: 3.days.ago)

      get interviews_path

      expect(response.body).to include("Where you stand")
      # One round trip: the homework. The application and the machine's
      # receipt are not exchanges.
      expect(standing_cells).to eq([["Take-home", "1", "Reserv — Senior Engineer", "you", "3d"]])
      expect(standing_row("Take-home")).to include(interview_path(job))
    end

    it "names the FURTHEST rung reached, not the latest beat" do
      job.notes.create!(tag: :interview, occurred_at: 4.days.ago)
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago)

      get interviews_path

      expect(standing_cells.first.first).to eq("Interview")
    end

    it "marks whose move it is and leaves the rest alone" do
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago)
      other = user.job_applications.create!(company: "Bluestaq")
      other.notes.create!(tag: :availability, occurred_at: 3.days.ago)
      other.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 2.days.from_now)

      get interviews_path

      # Bluestaq got further, so it leads; nothing is owed on a booked one.
      expect(standing_cells.map { |cells| [cells[0], cells[3]] })
        .to eq([["Scheduled", "them"], ["Availability", "you"]])
      expect(response.body.scan(/is-yours/).length).to eq(1)
    end

    # The filter and the search narrow the WALL. Where things stand is a fact
    # about the whole board, the same way the strips above it are.
    it "ignores the status chip and the search box" do
      job.notes.create!(tag: :offer, occurred_at: 1.day.ago)

      get interviews_path(status: :rejected, q: "nothing matches this")

      expect(standing_row("Offer")).to include("Reserv")
    end
  end

  describe "the never-answered line" do
    # The two numbers on the line, flattened: [total, in the past month].
    def silence_figures
      line = response.body[/<div class="interview-silence">(.*?)<\/div>/m].to_s
      line.gsub(/<[^>]+>/, " ").scan(/\d+/).map(&:to_i)
    end

    it "counts one nobody has answered, and dates it from the application" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 3.days.ago)
      job.notes.create!(tag: :acknowledged, occurred_at: 3.days.ago)

      get interviews_path

      expect(silence_figures).to eq([1, 1])
    end

    it "holds an old one in the total and out of the month" do
      old = user.job_applications.create!(company: "Reserv")
      old.notes.create!(tag: :applied, occurred_at: 3.months.ago)
      fresh = user.job_applications.create!(company: "Bluestaq")
      fresh.notes.create!(tag: :applied, occurred_at: 2.days.ago)

      get interviews_path

      expect(silence_figures).to eq([2, 1])
    end

    it "says nothing when every application has been answered" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 3.days.ago)
      job.notes.create!(tag: :heard_back, occurred_at: 1.day.ago)

      get interviews_path

      expect(response.body).not_to include("never answered")
    end

    # A fact about the whole board, like the strips above it.
    it "ignores the status chip and the search box" do
      job = user.job_applications.create!(company: "Reserv")
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago)

      get interviews_path(status: :rejected, q: "nothing matches this")

      expect(silence_figures).to eq([1, 1])
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

    # Each chip is a link that keeps the query, so its number has to be the
    # number of rows tapping it lands on. Counted off the board instead, a
    # search for one company printed the whole board's totals beside every
    # chip - true of nothing on screen, and wrong about where the link went.
    describe "the status chips during a search" do
      before do
        user.job_applications.create!(company: "Netflix Games", status: :rejected)
        user.job_applications.create!(company: "Netflix Studios", status: :closed)
        user.job_applications.create!(company: "Hooli", status: :rejected)
      end

      it "counts only the matches in each status" do
        get interviews_path(q: "netflix", status: :all)

        expect(chip_count("All")).to eq(3)
        expect(chip_count("Rejected")).to eq(1)
        expect(chip_count("Closed")).to eq(1)
        expect(chip_count("Live")).to eq(1)
      end

      # Hooli is rejected and on the board, and has nothing to do with this
      # search. Before, it was counted on the Rejected chip regardless.
      it "leaves out a row the query never matched" do
        get interviews_path(q: "netflix", status: :all)

        expect(chip_count("Rejected")).to eq(1)
      end

      # A chip whose status the search emptied prints a zero rather than the
      # count it would have had.
      it "says zero for a status with no matches" do
        get interviews_path(q: "hooli", status: :all)

        expect(chip_count("Rejected")).to eq(1)
        expect(chip_count("Live")).to eq(0)
        expect(chip_count("Offers")).to eq(0)
      end

      # The count and the wall are one answer read two ways: whatever a chip
      # promises, tapping it has to show.
      it "matches what the chip actually opens" do
        get interviews_path(q: "netflix", status: :all)
        promised = chip_count("Rejected")

        get interviews_path(q: "netflix", status: :rejected)

        expect(card_order.size).to eq(promised)
      end

      it "goes back to the whole board once the query is cleared" do
        get interviews_path(status: :all)

        # Netflix + Anrok live, Netflix Games + Hooli rejected, Studios closed.
        expect(chip_count("All")).to eq(5)
        expect(chip_count("Rejected")).to eq(2)
      end
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

    it "stores the pay and the location as typed" do
      patch interview_path(job),
        params: { job_application: { location: "Remote", pay: "160-170 + commissions" } }

      expect(job.reload.location).to eq("Remote")
      expect(job.pay).to eq("160-170 + commissions")
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

  describe "POST /interviews/:id/merge" do
    let(:keep) { user.job_applications.create!(company: "Workstream", role: "Staff Engineer") }
    let(:drop) { user.job_applications.create!(company: "Workstream") }

    it "offers the other rows, the same company first" do
      drop
      user.job_applications.create!(company: "Acme")

      get interview_path(keep)

      expect(response.body).to include("Merge a duplicate")
      expect(response.body.index("Same company")).to be < response.body.index("Everything else")
    end

    it "folds the chosen row into the one whose page it is" do
      note = drop.notes.create!(tag: :acknowledged, occurred_at: 1.hour.ago)

      post merge_interview_path(keep), params: { other_id: drop.id }

      expect(response).to redirect_to(interview_path(keep))
      expect(note.reload.job_application_id).to eq(keep.id)
      expect(JobApplication.exists?(drop.id)).to be(false)
    end

    it "lands on jobhunt's row when merged from the other one" do
      keep.notes.create!(tag: :applied, source: "jobhunt", occurred_at: 2.hours.ago)

      post merge_interview_path(drop), params: { other_id: keep.id }

      expect(response).to redirect_to(interview_path(keep))
      expect(flash[:notice]).to eq("Merged ##{drop.id} into this one.")
      expect(JobApplication.exists?(drop.id)).to be(false)
    end

    it "can't reach somebody else's row" do
      stranger = create(:user).job_applications.create!(company: "Workstream")
      note = stranger.notes.create!(tag: :applied, occurred_at: 1.hour.ago)

      post merge_interview_path(keep), params: { other_id: stranger.id }

      expect(JobApplication.exists?(stranger.id)).to be(true)
      expect(note.reload.job_application_id).to eq(stranger.id)
    end
  end

  describe "moving a note to another application" do
    let!(:job) { user.job_applications.create!(company: "Aledade PBC", role: "Staff Engineer") }
    let!(:sibling) { user.job_applications.create!(company: "Aledade PBC", role: "Principal Engineer") }
    let!(:note) { job.notes.create!(tag: :heard_back, body: "They wrote.", occurred_at: 1.hour.ago) }

    # The picker it is moved with, in the order the options come out.
    def move_options
      block = response.body[/<select[^>]*name="job_note\[job_application_id\]".*?<\/select>/m]
      block.to_s.scan(/<option[^>]*>([^<]+)</).flatten.map(&:strip)
    end

    it "offers the row it is on first, then the same company" do
      user.job_applications.create!(company: "Zebra")

      get interview_path(job)

      expect(move_options.first(2))
        .to eq(["Aledade PBC — Staff Engineer", "Aledade PBC — Principal Engineer"])
      expect(move_options).to include("Zebra")
    end

    it "keeps a settled row out of the general list" do
      user.job_applications.create!(company: "Zebra", status: :rejected)

      get interview_path(job)

      expect(move_options).not_to include("Zebra")
    end

    it "moves the beat and lands on the row it moved to" do
      patch interview_note_path(job, note), params: { job_note: { job_application_id: sibling.id } }

      expect(response).to redirect_to(interview_path(sibling))
      expect(note.reload.job_application_id).to eq(sibling.id)
    end

    it "refuses a row off somebody else's board" do
      stranger = create(:user).job_applications.create!(company: "Aledade PBC")

      patch interview_note_path(job, note), params: { job_note: { job_application_id: stranger.id } }

      expect(note.reload.job_application_id).to eq(job.id)
    end

    it "takes the booking's calendar row with it" do
      booking = job.notes.create!(tag: :scheduled, occurred_at: 1.hour.ago,
        follow_up_at: 3.days.from_now)

      patch interview_note_path(job, booking),
        params: { job_note: { job_application_id: sibling.id } }

      expect(booking.reload.follow_up_item.name).to eq("Interview: Aledade PBC")
      expect(booking.follow_up_item.notes).to include(sibling.interview_url)
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

  # The board's `url` is the EMPLOYER's posting and goes dead; the local one is
  # the working copy. The pointer only ever existed the other way round, so
  # reaching it from a timeline meant searching jobhunt by company.
  describe "the local posting link" do
    let(:job) { user.job_applications.create!(company: "GitLab") }

    it "shows it once the row knows its local id" do
      job.update!(jobhunt_job_id: 182)

      get interview_path(job)

      expect(response.body).to include(">the local posting</a>")
      expect(response.body).to include("http://localhost:8790/jobs/182")
    end

    it "says nothing for a row jobhunt never touched" do
      get interview_path(job)

      expect(response.body).not_to include("the local posting")
    end

    # jobhunt names the row it is writing to and the board ignores the rest of
    # `job_application` on that branch, so this had to be let through on its own.
    it "takes the id from a note jobhunt files on an existing row" do
      post interviews_path, params: {
        job_application_id: job.id,
        job_application:    { jobhunt_job_id: 182 },
        job_note:           { tag: :applied, source: "jobhunt", body: "Submitted" },
      }

      expect(job.reload.jobhunt_job_id).to eq(182)
    end

    # A second job at the same company must not repoint the row at itself.
    it "never overwrites an id the row already has" do
      job.update!(jobhunt_job_id: 182)

      post interviews_path, params: {
        job_application_id: job.id,
        job_application:    { jobhunt_job_id: 999 },
        job_note:           { tag: :note, body: "Another role" },
      }

      expect(job.reload.jobhunt_job_id).to eq(182)
    end

    # The note-only shape, which carries no `job_application` key at all -
    # `job_params` would raise on it.
    it "still takes a note with no application attributes beside it" do
      post interviews_path, params: {
        job_application_id: job.id,
        job_note:           { tag: :note, source: "jobhunt", body: "Form reopened" },
      }

      expect(response).to have_http_status(:redirect)
      expect(job.notes.reload.map(&:body)).to eq(["Form reopened"])
    end

    it "takes it on a row jobhunt opens itself" do
      post interviews_path, params: {
        job_application: { company: "Huntress", jobhunt_job_id: 463 },
        job_note:        { tag: :applied, source: "jobhunt" },
      }

      expect(user.job_applications.find_by(company: "Huntress").jobhunt_job_id).to eq(463)
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

    # `simple_format` collapsed leading spaces on sight, so aligned sub-notes
    # arrived on the page squashed against the margin.
    it "prints a note's indentation verbatim" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Call notes:\n      - asked about Rails")

      get interview_path(job)

      expect(response.body).to include("Call notes:\n      - asked about Rails")
    end

    # A note that keeps the whole message runs to several screens, and a link to
    # the mail it came from is no use at the far end of it.
    it "puts the mail's link above the note it came from" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(
        body: "Thanks for applying.", source: "Email", url: "https://ardesian.com/emails/51703",
      )

      get interview_path(job)

      expect(response.body.index("emails/51703")).to be < response.body.index("Thanks for applying.")
    end

    # A ROW IS ONE LINE. Twelve mails printed in full is a mailbox rather than a
    # history, so the row says what it was and the message is behind the arrow.
    it "shows one line per beat and keeps the message behind an arrow" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(
        tag:          :scheduled,
        summary:      "Hiring manager round booked for Tue 3pm",
        body:         "Hi Rocco,\n\nYour video interview is scheduled for Tue at 3:00 PM MDT.",
        follow_up_at: 2.days.from_now,
      )

      get interview_path(job)

      expect(response.body).to include("Hiring manager round booked for Tue 3pm")
      expect(response.body).to include("<summary>The whole of it</summary>")
      expect(response.body.index("The whole of it"))
        .to be < response.body.index("Your video interview is scheduled")
    end

    # An arrow that opens onto the same sentence again is a control that does
    # nothing.
    it "gives a one-line beat no arrow to open" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(body: "Left a voicemail.")

      get interview_path(job)

      expect(response.body).to include("Left a voicemail.")
      expect(response.body).not_to include("The whole of it")
    end

    # A call and the transcript of that call are one thing that happened. The
    # transcript was a separate section further down that you had to know to go
    # and look in.
    it "carries the recording on the beat it belongs to" do
      job = user.job_applications.create!(company: "Acme")
      note = job.notes.create!(tag: :recruiter_call, body: "Spoke to Dana.")
      transcript = job.transcripts.create!(
        job_note: note,
        title:    "Recruiter screen",
        turns:    [
          { "speaker" => "Speaker 1", "text" => "Tell me about yourself." },
          { "speaker" => "Speaker 2", "text" => "I have been writing Rails for ten years." },
        ],
      )
      transcript.rename_speakers!("Speaker 2" => { "name" => "Rocco", "me" => "1" })

      get interview_path(job)

      expect(response.body).to include("Recruiter screen")
      expect(response.body).to include("I have been writing Rails for ten years.")
      expect(response.body).to include("is-mine")
    end

    # The whole path: the form posts it, the controller permits it, the row
    # shows it. Permitting these is a splat of `JobNote::SENTIMENT.keys`, which
    # is exactly the sort of thing that silently permits nothing.
    it "saves a rating and a summary typed on the note itself" do
      job = user.job_applications.create!(company: "Acme")
      note = job.notes.create!(tag: :interview, body: "Panel with three of them.")

      patch interview_note_path(job, note), params: {
        job_note: {
          summary:    "Panel went long, liked two of the three",
          did_well:   7,
          liked_them: 9,
        },
      }

      expect(note.reload.summary).to eq("Panel went long, liked two of the three")
      expect(note.sentiment).to eq(did_well: 7, liked_them: 9)
    end

    # The sliders post on every save because a range input always does. Editing
    # the words must not leave a score behind.
    it "leaves a beat unrated when the sliders were never moved" do
      job = user.job_applications.create!(company: "Acme")
      note = job.notes.create!(tag: :interview, body: "Panel with three of them.")

      patch interview_note_path(job, note), params: {
        job_note: {
          body:       "Panel with three of them. Two engineers and the manager.",
          did_well:   JobNote::SENTIMENT_UNRATED,
          liked_them: JobNote::SENTIMENT_UNRATED,
        },
      }

      expect(note.reload.body).to include("Two engineers and the manager")
      expect(note).not_to be_rated
      expect(note.sentiment).to eq({})
    end

    # How it went, on the row. Both numbers, because the whole reason there are
    # two of them is that they disagree.
    it "shows what he scored a conversation out of ten" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :interview, body: "Panel.", did_well: 8, liked_them: 4)

      get interview_path(job)

      expect(response.body).to match(%r{did\s*<strong>8</strong>/10})
      expect(response.body).to match(%r{liked\s*<strong>4</strong>/10})
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

  # The index answers this for the whole board. This page is the one open while
  # something is being written down, and it used to answer none of it.
  # "I got an availability check from Podium which included notes of what to
  # prepare." Found in the mail rather than typed, and shown where the work is.
  describe "what they asked you to prepare" do
    let(:job) { user.job_applications.create!(company: "Podium") }

    it "reads the ask back out of the beat it arrived in" do
      job.notes.create!(
        tag:         :availability,
        occurred_at: 1.day.ago,
        body:        <<~MAIL,
          A 30-minute Zoom interview with the hiring manager, Evelyn Sharp.

          To make the most of this conversation, come ready to walk through:

          * An AI system you've built or shipped that takes action.
        MAIL
      )

      get interview_path(job)

      expect(response.body).to include("What they asked you to prepare")
      expect(response.body).to include("come ready to walk through")
      expect(response.body).to include("An AI system you&#39;ve built or shipped that takes action")
    end

    # Which round it belongs to is the whole question when one mail lays out
    # four of them - and it is said as what the ask is FOR, because a round in
    # a chip reads as a round that has been booked.
    it "says which round the ask is for" do
      job.notes.create!(
        tag:         :recruiter_call,
        occurred_at: 2.days.ago,
        body:        "What to expect:\n\n1. A technical screen, an hour of live coding.",
      )

      get interview_path(job)

      expect(response.body).to include("for the technical interview")
    end

    # It is a page of somebody else's mail about a round that is usually weeks
    # off. The count on the summary is what says there is something in here.
    it "stays closed" do
      job.notes.create!(
        tag:         :availability,
        occurred_at: 1.day.ago,
        body:        "Come ready to walk through:\n\n* An AI system you shipped.",
      )

      get interview_path(job)

      expect(response.body).to include('<details class="job-details job-asks">')
    end

    it "says nothing on an application nobody has asked anything of" do
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago, body: "Applied on their site.")

      get interview_path(job)

      expect(response.body).not_to include("What they asked you to prepare")
    end
  end

  describe "the standing banner on one application" do
    # Only the terms strip. The edit form below the panel carries a label for
    # each of these fields, so a bare search of the page finds "Location" on a
    # row that has not been given one.
    def terms_strip
      response.body[/<dl class="standing-terms">.*?<\/dl>/m].to_s
    end

    # Which option the Type dropdown opens on.
    def selected_tag
      block = response.body[/<select[^>]*name="job_note\[tag\]".*?<\/select>/m]
      block[/<option selected="selected" value="(\w+)"/, 1]
    end

    it "says whose move it is, how deep it got and how many rounds" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :heard_back, occurred_at: 2.days.ago, body: "Keen to talk")

      get interview_path(job)

      expect(response.body).to include("job-standing is-waiting")
      expect(response.body).to include("Reply to them")
      expect(response.body).to include("Heard back")
      expect(response.body).to include("Yours")
    end

    # Both at once - homework arriving before an interview already booked. The
    # frame goes to the appointment, the way the index orders its strips, and
    # the errand still gets its own line.
    it "leads on a booked interview and keeps the thing owed beside it" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 2.days.from_now)
      job.notes.create!(tag: :take_home, occurred_at: 1.hour.ago)

      get interview_path(job)

      expect(response.body).to include("job-standing is-booked")
      expect(response.body).to include("Take-home to do")
      expect(response.body).to include("Yours")
    end

    it "asks for the write-up of a slot that has passed" do
      job = user.job_applications.create!(company: "Acme")
      job.notes.create!(tag: :scheduled, occurred_at: 2.days.ago, follow_up_at: 1.hour.ago)

      get interview_path(job)

      expect(response.body).to include("how did it go?")
      expect(selected_tag).to eq("recruiter_call")
    end

    # Nothing is owed on a row that is over, and the status control below the
    # banner already says which way it went.
    it "claims no move on a rejected application" do
      job = user.job_applications.create!(company: "Acme", status: :rejected)
      job.notes.create!(tag: :heard_back, occurred_at: 2.days.ago, body: "Keen to talk")

      get interview_path(job)

      expect(response.body).to include("job-standing")
      expect(response.body).not_to include("Reply to them")
      expect(response.body).not_to include(">Move<")
    end

    # Read off the panel while deciding between two applications, which is why
    # they are printed as typed: a band, a base plus commission, a number with
    # a day-in-office constraint hanging off it.
    it "prints what it pays and where it is" do
      job = user.job_applications.create!(
        company:  "Acme",
        location: "Salt Lake City, 4 days in office",
        pay:      "160-170 + commissions",
      )
      job.notes.create!(tag: :heard_back, occurred_at: 2.days.ago, body: "Keen to talk")

      get interview_path(job)

      expect(terms_strip).to include("160-170 + commissions")
      expect(terms_strip).to include("Salt Lake City, 4 days in office")
    end

    it "leaves out the half that has not been written down" do
      job = user.job_applications.create!(company: "Acme", pay: "210k")
      job.notes.create!(tag: :heard_back, occurred_at: 2.days.ago, body: "Keen to talk")

      get interview_path(job)

      expect(terms_strip).to include(">Pay<")
      expect(terms_strip).not_to include(">Location<")
    end

    # The panel is otherwise the timeline's read, but a band worth weighing is
    # on the row before anybody has replied to it.
    it "opens the panel for terms alone on a row with no timeline" do
      job = user.job_applications.create!(company: "Acme", pay: "160-170 + commissions")

      get interview_path(job)

      expect(response.body).to include("job-standing")
      expect(terms_strip).to include("160-170 + commissions")
    end

    it "stays off a row with nothing on its timeline" do
      job = user.job_applications.create!(company: "Acme")

      get interview_path(job)

      expect(response.body).not_to include("job-standing")
      expect(selected_tag).to eq("applied")
    end
  end
end
