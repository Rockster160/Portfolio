require "rails_helper"

# One-off, deleted after the deploy. Here because it rewrites live rows and
# "safe to run twice" is a claim worth checking before it touches production.
RSpec.describe "normalize_reminder_recurrence script" do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  def run!
    load Rails.root.join("lib/scripts/normalize_reminder_recurrence.rb")
  end

  def reminder!(recurrence)
    BuddyReminder.create!(
      user: user, byte_conversation: convo, body: "Grab my Loops",
      fire_at: 1.hour.from_now, recurrence: recurrence
    )
  end

  def watch!(body:, scope: "item", one_shot: false)
    BuddyWatch.create!(
      user: user, byte_conversation: convo, kind: "prompt", body: body,
      trigger_scope: scope, match: {}, one_shot: one_shot
    )
  end

  before { allow($stdout).to receive(:puts) }

  it "rewrites the old recurrence shape into the shared one" do
    rem = reminder!({ "kind" => "weekly", "weekday" => "wednesday", "at" => "20:00" })

    run!

    expect(rem.reload.recurrence).to include("freq" => "weekly", "by_day" => ["wed"], "at" => "20:00")
    expect(rem.recurrence).not_to have_key("kind")
  end

  it "leaves one already in the shared shape alone" do
    rem = reminder!({ "freq" => "daily", "at" => "09:00" })

    expect { run! }.not_to(change { rem.reload.recurrence })
  end

  it "puts the bell back on a repeating watch that used to get one at delivery" do
    watch = watch!(body: "Claude list got a new item in Ocs-Backend.")

    run!

    expect(watch.reload.body).to eq("🔔 Claude list got a new item in Ocs-Backend.")
  end

  it "gives a deploy watch the template it was already being rendered as" do
    watch = watch!(body: "Ping me when a deploy finishes.", scope: "deploy")

    run!

    expect(watch.reload.body).to eq(Buddy::WatchMessage::DEPLOY_DEFAULT)
    expect(Buddy::Template).to be_templated(watch.body)
  end

  # A one-shot goes through the model, which writes its own line - a glyph on
  # the front of the brief would end up in the middle of a composed sentence.
  it "leaves a one-shot alone" do
    watch = watch!(body: "grab the prescription", one_shot: true)

    expect { run! }.not_to(change { watch.reload.body })
  end

  it "leaves one that already opens with a glyph" do
    watch = watch!(body: "📥 something landed")

    expect { run! }.not_to(change { watch.reload.body })
  end

  it "leaves one that's already a template" do
    watch = watch!(body: "{{ name }} landed")

    expect { run! }.not_to(change { watch.reload.body })
  end

  it "is safe to run twice" do
    watch = watch!(body: "Claude list got a new item.")
    rem   = reminder!({ "kind" => "daily", "at" => "09:00" })

    run!
    after_first = [watch.reload.body, rem.reload.recurrence]

    run!

    expect([watch.reload.body, rem.reload.recurrence]).to eq(after_first)
  end
end
