require "rails_helper"

# Behavioral spec for the one-off that replaces Eve's dead flower-bed watch.
# DELETE once the script has been run in prod.
RSpec.describe "fix_flower_bed_watch script" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Suki", last_message_at: Time.current) }

  let!(:watch) {
    BuddyWatch.create!(
      user: user, byte_conversation: convo, kind: :prompt, body: "Check the front flower bed",
      trigger_scope: :item, match: {},
      listener: "item:action:added item:list:name:/^Daily front flower bed check$/"
    )
  }

  # The script hardcodes watch 14 / user 4, so the spec points the same code at
  # records it can actually make. Anchored subs: an unanchored one hits the
  # comment above the flag instead of the flag.
  def run!(dry_run:)
    source = Rails.root.join("lib/scripts/fix_flower_bed_watch.rb").read
    # Matches whichever way the flag is currently set. Pinning it to `true`
    # meant the spec silently stopped controlling the flag the moment somebody
    # flipped it to run the thing, and then "changes nothing on a dry run"
    # started writing.
    source = source.sub(/^DRY_RUN = (?:true|false)$/, "DRY_RUN = #{dry_run}")
    source = source.sub(/^WATCH_ID  = 14$/, "WATCH_ID  = #{watch.id}")
    source = source.sub("User.find_by(id: 4)", "User.find_by(id: #{user.id})")
    # The script assigns these at top level, so a second eval would warn and
    # keep the first run's flag. stub_const can't help - the eval does the
    # assigning. This spec is deleted with the script.
    %w[DRY_RUN WATCH_ID FIRE_HOUR BODY].each { |c|
      Object.send(:remove_const, c) if Object.const_defined?(c) # rubocop:disable RSpec/RemoveConst
    }
    capture_stdout { eval(source, TOPLEVEL_BINDING) } # rubocop:disable Security/Eval
  end

  def capture_stdout
    original = $stdout
    $stdout  = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  it "changes nothing on a dry run" do
    expect { run!(dry_run: true) }.not_to(change(BuddyReminder, :count))

    expect(watch.reload.cancelled_at).to be_nil
  end

  it "reports what it would do" do
    output = run!(dry_run: true)

    expect(output).to include("never existed")
    expect(output).to include("DRY_RUN")
  end

  it "retires the watch and leaves a daily reminder in its place" do
    expect { run!(dry_run: false) }.to change(BuddyReminder, :count).by(1)

    expect(watch.reload.cancelled_at).to be_present
    reminder = BuddyReminder.last
    expect(reminder.body).to eq("Check the front flower bed")
    expect(reminder.recurrence["freq"]).to eq("daily")
    expect(reminder.recurrence["at"]).to eq("08:00")
    expect(reminder.fire_at).to be > Time.current
  end

  # She should get a push, which is the whole reason this is a reminder rather
  # than a calendar row.
  it "makes a reminder, not a silent agenda task" do
    run!(dry_run: false)

    expect(BuddyReminder.last.kind).to eq("reminder")
    expect(AgendaSchedule.count).to eq(0)
  end

  it "is safe to run twice" do
    run!(dry_run: false)

    expect { run!(dry_run: false) }.not_to(change(BuddyReminder, :count))
  end
end
