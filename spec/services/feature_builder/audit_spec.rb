require "rails_helper"

RSpec.describe FeatureBuilder::Audit do
  let(:user) { User.me }
  let(:tz) { ActiveSupport::TimeZone[user.timezone] }
  let(:now) { tz.parse("2026-11-17 14:00:00") }

  def audit_at(time)
    FeatureBuild.create!(user: user, title: "Audit", request: "brief", kind: :audit, created_at: time)
  end

  describe ".window" do
    it "covers the last day when there's never been an audit" do
      FeatureBuild.create!(user: user, title: "Feature", request: "build it", created_at: now - 2.hours)

      span = described_class.window(user, now: now)

      expect(span.first).to eq(now - 24.hours)
      expect(span.last).to eq(now)
    end

    it "opens an hour before the last audit did" do
      audit_at(now - 5.hours)
      audit_at(now - 30.hours)

      expect(described_class.window(user, now: now).first).to eq(now - 6.hours)
    end

    it "reads no more than a week back however long ago the last one was" do
      audit_at(now - 30.days)

      expect(described_class.window(user, now: now).first).to eq(now - 7.days)
    end

    it "only counts this person's audits" do
      other = create(:user)
      FeatureBuild.create!(user: other, title: "Audit", request: "brief", kind: :audit, created_at: now - 2.hours)

      expect(described_class.window(user, now: now).first).to eq(now - 24.hours)
    end
  end

  describe ".brief" do
    let(:span) { (now - 6.hours)..now }

    it "puts a note first, as the thing to fix" do
      brief = described_class.brief(user, span, "reminders fire twice")

      expect(brief).to include("**reminders fire twice**", "it comes first")
      expect(brief.index("reminders fire twice")).to be < brief.index("WHERE THE DAY IS")
    end

    it "leaves it to the session's judgement without one" do
      expect(described_class.brief(user, span, "")).to include("judge for yourself")
    end

    it "carries the window and everything the daily audit knows about reading it" do
      brief = described_class.brief(user, span, "")

      expect(brief).to include(
        "Review the 6 hours from",
        ByteDailyAudit.stamp(span.first),
        "prod-query.sh",
        "HARD RULES",
        "NOT FINDINGS",
        "builder-pr close",
        "Daily Audit",
      )
    end

    it "hands over the window's audit notes and errors" do
      thread = user.byte_conversations.create!(name: :Buddy, mode: :buddy)
      note = thread.byte_messages.create!(
        user:       user,
        direction:  :outbound,
        state:      :sent,
        body:       "Note: that should have been a reminder",
        metadata:   { kind: Buddy::AuditNotes::KIND },
        created_at: now - 1.hour,
      )

      brief = described_class.brief(user, span, "")

      expect(brief).to include("message #{note.id}", "Errors reported in the window")
    end
  end

  describe ".title" do
    it "names the window" do
      expect(described_class.title((now - 24.hours)..now)).to eq("Audit of the last 24 hours")
    end
  end
end
