require "rails_helper"

# A cron that CronParse can't read resolves to next_trigger_at: nil, which is
# indistinguishable from a task that has no schedule at all — it just never runs
# again, silently. These are what stands in front of that.
RSpec.describe Task, "cron validation" do
  let(:user) { create(:user) }

  def build_task(cron)
    user.tasks.build(name: "Subject", listener: "tell:sub", code: "// noop", cron: cron)
  end

  it "accepts every cron form currently live in production" do
    [
      "1 * * * *",
      "0 7 * * *",
      "0 9 1 */2 *",
      "0 6 * * 1,3,5",
      "0 0 1 2,4,6,8,10,12 *",
      "0 7 * * 4 | 0 7 * * 0",
    ].each do |cron|
      expect(build_task(cron)).to be_valid, "expected #{cron.inspect} to be accepted"
    end
  end

  it "accepts a blank cron" do
    expect(build_task(nil)).to be_valid
    expect(build_task("")).to be_valid
  end

  it "rejects a cron it cannot read" do
    task = build_task("not a cron")

    expect(task).not_to be_valid
    expect(task.errors[:cron].join).to include("couldn't read")
  end

  describe "against the user's own anchors" do
    before do
      user.anchors.create!(key: "sun:sunset")
      user.anchors.create!(key: "trash:pickup")
    end

    it "accepts an anchor the user has, with or without an offset" do
      ["sun:sunset", "sun:sunset-5m", "trash:pickup+1h30m", "sun:sunset-5m | 0 6 * * *"].each do |cron|
        expect(build_task(cron)).to be_valid, "expected #{cron.inspect} to be accepted"
      end
    end

    # The point of the redesign: a user-created anchor validates without anyone
    # adding it to a list in Ruby.
    it "accepts an anchor created moments ago" do
      user.anchors.create!(key: "school:bell")

      expect(build_task("school:bell-10m")).to be_valid
    end

    # An anchor that doesn't exist yet does NOT block the save. A task written
    # before its feeder is a legitimate half-finished state, and forcing one
    # build order would be worse than a warning.
    it "saves against an anchor that doesn't exist yet" do
      task = build_task("sun:sunet-5m")

      expect(task).to be_valid
      expect(task.save).to be(true)
    end

    it "warns about it instead, naming the anchors that do exist" do
      task = build_task("sun:sunet-5m")

      expect(task.cron_warnings.join).to include("sun:sunet", "doesn't exist yet")
      expect(task.cron_warnings.join).to include("sun:sunset", "trash:pickup")
    end

    it "has nothing to warn about once the anchor exists" do
      expect(build_task("sun:sunset-5m").cron_warnings).to be_empty
    end

    it "warns once per missing anchor in a multi-anchor cron" do
      task = build_task("sun:sunset-5m | school:bell-1h | tide:high+2h")

      expect(task).to be_valid
      expect(task.cron_warnings.length).to eq(2)
      expect(task.cron_warnings.join).to include("school:bell", "tide:high")
      expect(task.cron_warnings.join).not_to include("sun:sunset doesn't exist")
    end

    it "warns rather than blocking when another user owns the anchor" do
      create(:user).anchors.create!(key: "tide:high")
      task = build_task("tide:high-1h")

      expect(task).to be_valid
      expect(task.cron_warnings.join).to include("tide:high")
    end

    it "explains a malformed offset rather than calling the anchor unknown" do
      task = build_task("sun:sunset-5")

      expect(task).not_to be_valid
      expect(task.errors[:cron].join).to include("offset", "sun:sunset-5m")
    end

    # Unreadable is different from unsatisfied: no amount of setting things up
    # later makes "nonsense" a schedule, so that still blocks.
    it "still rejects a mix where one side is unreadable" do
      expect(build_task("sun:sunset-5m | nonsense")).not_to be_valid
      expect(build_task("sun:sunset-5m | sun:sunset-5")).not_to be_valid
    end

    it "still validates once the anchor has no occurrences left" do
      expect(build_task("sun:sunset-5m")).to be_valid
    end
  end

  it "points at how to make one when the user has no anchors at all" do
    task = build_task("sun:sunset-5m")

    expect(task).to be_valid
    expect(task.cron_warnings.join).to include("doesn't exist yet", "Anchor.set")
  end

  it "has nothing to warn about for a plain cron" do
    expect(build_task("0 6 * * *").cron_warnings).to be_empty
    expect(build_task(nil).cron_warnings).to be_empty
  end

  # JilRunnerWorker finds tasks by `pending` and Jil::Executor stamps
  # last_trigger_at afterwards. If that stamp could be blocked by an unreadable
  # cron on a legacy row, the task would stay pending and re-run forever.
  it "still lets an existing row stamp last_trigger_at when its cron is unreadable" do
    task = build_task("0 6 * * *")
    task.save!
    task.update_columns(cron: "garbage that predates this validation")

    expect(task.update(last_trigger_at: Time.current)).to be(true)
  end

  it "blocks the save the moment that row's cron is edited" do
    task = build_task("0 6 * * *")
    task.save!
    task.update_columns(cron: "garbage that predates this validation")

    expect(task.update(cron: "still garbage")).to be(false)
  end
end
