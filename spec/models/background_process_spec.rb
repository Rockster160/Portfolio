require "rails_helper"

# The strip in the corner of the hero. Everything about this model is in
# service of one thing: a script that has just been restarted, and knows only
# what it is working on, can still find and finish what it left behind.
RSpec.describe BackgroundProcess do
  let(:user) { create(:user) }

  # Ageing a heartbeat is the only way to watch one go quiet, and it has to
  # skip the model: `report!` stamps `heartbeat_at` on every save, so an
  # ordinary update would put it straight back to now.
  # rubocop:disable Rails/SkipsModelValidations

  def report(**attrs)
    described_class.report!(user: user, key: "jobhunt:line", **attrs)
  end

  describe ".report!" do
    it "starts one for a key with nothing live behind it" do
      process = report(name: "Preparing", current: 1, total: 13)

      expect(process).to be_running
      expect(process.started_at).to be_present
      expect(described_class.live_for(user).count).to eq(1)
    end

    it "steps the one already running rather than making a second" do
      first = report(name: "Preparing", current: 1, total: 13)
      again = report(current: 4)

      expect(again.id).to eq(first.id)
      expect(again.current).to eq(4)
      expect(described_class.live_for(user).count).to eq(1)
    end

    # The half that makes a partial report safe to send. A caller that says
    # only how far along it is must not blank what it called itself.
    it "leaves out what the report did not mention" do
      report(name: "Preparing", total: 13, links: [{ label: "Line", url: "/line" }])
      stepped = report(current: 2)

      expect(stepped.name).to eq("Preparing")
      expect(stepped.total).to eq(13)
      expect(stepped.links.first["label"]).to eq("Line")
    end

    # A report that changes nothing is still a report: it is how a long step
    # says it has not died.
    it "moves the heartbeat even when nothing else changed" do
      process = report(name: "Preparing", current: 1)
      process.update_columns(heartbeat_at: 20.minutes.ago)

      expect(report(current: 1).heartbeat_at).to be_within(5.seconds).of(Time.current)
    end

    it "keeps one person's work off another's strip" do
      other = create(:user)
      report(name: "Preparing")
      described_class.report!(user: other, key: "jobhunt:line", name: "Preparing")

      expect(described_class.live_for(user).count).to eq(1)
      expect(described_class.live_for(other).count).to eq(1)
    end

    # A caller that says it has finished has finished, whichever route it said
    # it on - the strip and the database must not disagree about that.
    it "treats a report of finished as the end of it" do
      report(name: "Preparing")
      done = report(state: :finished)

      expect(done.finished_at).to be_present
      expect(described_class.live_for(user)).to be_empty
    end

    it "refuses a key that could not survive a URL" do
      expect { described_class.report!(user: user, key: "jobhunt/line.json", name: "No") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # The chip is a corner of a screen, not a line in a log - and a reporter
  # three repos away has no idea how wide the hero is.
  describe "how long it is allowed to be" do
    it "cuts a name to something that fits the bold line" do
      process = report(name: "Left Fieldwire by Hilti filled but not sent")

      expect(process.name.length).to eq(described_class::MAX_NAME)
      expect(process.name).to eq("Left Fieldwire by...")
    end

    # Not drawn: it is the chip's hover title. Still cut, because it travels in
    # every broadcast and a caller will hand it a whole exception message.
    it "cuts a detail too, with a little more room" do
      process = report(name: "Preparing", detail: "a" * 90)

      expect(process.detail.length).to eq(described_class::MAX_DETAIL)
    end

    it "leaves one that already fits exactly alone" do
      process = report(name: "Waiting on you", detail: "8 questions · 12 to send")

      expect(process.name).to eq("Waiting on you")
      expect(process.detail).to eq("8 questions · 12 to send")
    end

    it "keeps a blank detail blank rather than making one up" do
      expect(report(name: "Preparing", detail: nil).detail).to be_nil
    end
  end

  describe "links" do
    it "takes a list of labelled ones" do
      process = report(name: "Preparing", links: [
        { label: "Posting", url: "https://boards.greenhouse.io/x/jobs/1" },
        { label: "Line", url: "http://localhost:8790/line" },
      ])

      expect(process.links.pluck("label")).to eq(%w[Posting Line])
    end

    # `url:` is what somebody with one link writes without being told to.
    it "takes the one-link shorthand" do
      process = report(name: "Preparing", url: "/emails/51716")

      expect(process.links).to eq([{ "label" => "/emails/51716", "url" => "/emails/51716" }])
    end

    # A pill has to say something, and a row of them all reading "Open" says
    # nothing at all.
    it "labels an unlabelled one by where it goes" do
      process = report(name: "Preparing", links: ["https://www.lever.co/jobs/9"])

      expect(process.links.first["label"]).to eq("lever.co")
    end

    # These arrive from scripts and end up in `window.open`.
    it "drops anything that is not http or a path on this site" do
      process = report(name: "Preparing", links: [
        { label: "Bad", url: "javascript:alert(1)" },
        { label: "Good", url: "/interviews" },
      ])

      expect(process.links.pluck("label")).to eq(["Good"])
    end

    it "keeps a corner of a phone from becoming a menu" do
      process = report(name: "Preparing", links: (1..9).map { |n| "https://example.com/#{n}" })

      expect(process.links.length).to eq(described_class::MAX_LINKS)
    end

    # The same rule as every other field: a report that says nothing about the
    # links is not a report that there are none.
    it "leaves them alone when a later report does not mention them" do
      report(name: "Preparing", links: ["https://example.com/job"])
      stepped = report(current: 2)

      expect(stepped.links.length).to eq(1)
    end
  end

  describe ".clear!" do
    it "takes it off the strip" do
      report(name: "Preparing")
      described_class.clear!(user: user, key: "jobhunt:line")

      expect(described_class.live_for(user)).to be_empty
    end

    it "says nothing happened for a key with nothing behind it" do
      expect(described_class.clear!(user: user, key: "never:ran")).to be_nil
    end

    # Clearing says "stop showing me this", not "stop doing that" - so the work
    # carrying on has somewhere to report to.
    it "lets the next report put it back" do
      report(name: "Preparing", current: 2, total: 13)
      described_class.clear!(user: user, key: "jobhunt:line")
      resumed = report(name: "Preparing", current: 3, total: 13)

      expect(resumed).to be_running
      expect(described_class.live_for(user).count).to eq(1)
      expect(resumed.current).to eq(3)
    end
  end

  describe "#stale?" do
    it "is true once nothing has been heard for a while" do
      process = report(name: "Preparing")
      process.update_columns(heartbeat_at: 30.minutes.ago)

      expect(process.reload).to be_stale
    end

    # Waiting is stalled on purpose, and failed has already said so. Neither
    # needs to be told it has gone quiet.
    it "is false for work that is not claiming to be moving" do
      process = report(name: "Preparing", state: :waiting)
      process.update_columns(heartbeat_at: 30.minutes.ago)

      expect(process.reload).not_to be_stale
    end
  end

  describe ".live_for" do
    it "drops one nobody has heard from since yesterday" do
      process = report(name: "Preparing")
      process.update_columns(heartbeat_at: 2.days.ago)

      expect(described_class.live_for(user)).to be_empty
      expect(described_class.where(user: user).count).to eq(1)
    end

    # Neither will ever heartbeat again, and both are waiting on a person. Ageing
    # one out throws away the thing he was meant to come back to.
    it "keeps one that is parked waiting on him, however long it waits" do
      process = report(name: "Waiting on you", state: :waiting)
      process.update_columns(heartbeat_at: 3.days.ago)

      expect(described_class.live_for(user)).to eq([process])
    end

    it "keeps one that failed, for the same reason" do
      process = report(name: "Looking for new jobs", state: :failed)
      process.update_columns(heartbeat_at: 3.days.ago)

      expect(described_class.live_for(user)).to eq([process])
    end
  end

  describe ".note" do
    # A chip is a nicety. A worker that reports its own progress must not gain
    # a new way to die that the work itself never had.
    it "swallows what the bang version would raise" do
      expect(described_class.note(user: user, key: "not a key", name: "No")).to be_nil
    end
  end
end
# rubocop:enable Rails/SkipsModelValidations
