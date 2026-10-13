require "rails_helper"

# A reminder scheduled against a moment that MOVES. The anchor machinery and
# its expression syntax already existed for crons and derived triggers (see
# docs/jil_anchors.md); this is reminders using the same parser and the same
# re-resolution.
RSpec.describe BuddyReminder do
  describe "anchored to a moving time" do
    let(:user)   { create(:user) }
    let(:convo)  { user.byte_conversations.create!(name: "Byte") }
    let(:anchor) { Anchor.create!(user: user, key: "agenda:interview") }

    # Tomorrow, not today: an anchor only ever answers with what is still ahead,
    # so a fixture hour that has already gone by leaves every expression here
    # with nothing to resolve to.
    let(:noon)  { Time.current.tomorrow.change(hour: 12, min: 0) }
    let(:later) { noon + 2.days }

    def remind(expression, **attrs)
      # Validated on the way out: `fire_at` is derived, and running validation is
      # what fills it - for a caller that saves, and here.
      BuddyReminder.new(
        { user: user, byte_conversation: convo, body: "Grab the portfolio", anchor: expression }.merge(attrs),
      ).tap(&:valid?)
    end

    before { anchor.set_occurrence(noon, identifier: "1289") }

    it "takes its time from the anchor, with the offset applied" do
      reminder = remind("agenda:interview-30m")

      expect(reminder).to be_valid
      expect(reminder.fire_at).to be_within(1.second).of(noon - 30.minutes)
    end

    it "reads an offset the other way for an ask about afterwards" do
      expect(remind("agenda:interview+90m").fire_at).to be_within(1.second).of(noon + 90.minutes)
    end

    it "refuses a key nobody has created" do
      reminder = remind("agenda:dentist-30m")

      expect(reminder).not_to be_valid
      expect(reminder.errors[:anchor].join).to match(/agenda:dentist, which doesn't exist/)
    end

    it "refuses an expression that isn't one" do
      expect(remind("agenda:interview-5")).not_to be_valid
    end

    # A standing rule is a complete instruction on a week with nothing booked.
    it "parks a real key with nothing ahead of it" do
      anchor.occurrences.destroy_all

      reminder = remind("agenda:interview-30m")

      expect(reminder).to be_valid
      expect(reminder.fire_at).to be_nil
    end

    it "arms a parked one the moment something appears" do
      anchor.occurrences.destroy_all
      reminder = remind("agenda:interview-30m")
      reminder.save!

      anchor.set_occurrence(noon, identifier: "1289")

      expect(reminder.reload.fire_at).to be_within(1.second).of(noon - 30.minutes)
    end

    it "refuses a pinned one whose occurrence isn't there" do
      reminder = remind("agenda:interview[404]-30m")

      expect(reminder).not_to be_valid
      expect(reminder.errors[:anchor].join).to match(/occurrence of agenda:interview that isn't there/)
    end

    describe "whether it is a standing rule" do
      it "recurs when the expression names a class of them" do
        expect(remind("agenda:interview-30m")).to be_recurring
      end

      it "does not when it is pinned to one" do
        expect(remind("agenda:interview[1289]-30m")).not_to be_recurring
      end
    end

    describe "where it rolls to" do
      it "re-asks the anchor for the one after this" do
        anchor.set_occurrence(later, identifier: "1402")
        reminder = remind("agenda:interview-30m")

        expect(reminder.next_fire_at(from: noon)).to be_within(1.second).of(later - 30.minutes)
      end

      it "has no next when it was about one occurrence" do
        anchor.set_occurrence(later, identifier: "1402")

        expect(remind("agenda:interview[1289]-30m").next_fire_at(from: noon)).to be_nil
      end
    end

    describe "when the thing it hangs off moves" do
      it "follows it" do
        reminder = remind("agenda:interview[1289]-30m")
        reminder.save!

        anchor.set_occurrence(noon + 3.hours, identifier: "1289")

        expect(reminder.reload.fire_at).to be_within(1.second).of(noon + 2.hours + 30.minutes)
      end

      it "moves a standing rule onto whatever is next now" do
        reminder = remind("agenda:interview-30m")
        reminder.save!

        anchor.set_occurrence(noon + 45.minutes, identifier: "1289")

        expect(reminder.reload.fire_at).to be_within(1.second).of(noon + 15.minutes)
      end

      # A class rule is about the next of them, so nothing ahead is a wait. Only
      # a PINNED one is over when its occurrence goes.
      it "parks a standing rule when the last one ahead goes away" do
        reminder = remind("agenda:interview-30m")
        reminder.save!

        anchor.occurrences.destroy_all

        expect(reminder.reload.fire_at).to be_nil
        expect(reminder.cancelled_at).to be_nil
        expect(BuddyReminder.pending).to include(reminder)
      end

      it "is over, not instantly due, when the moment moves behind it" do
        reminder = remind("agenda:interview[1289]-30m")
        reminder.save!

        anchor.set_occurrence(2.days.ago, identifier: "1289")

        expect(reminder.reload.cancelled_at).to be_present
        expect(BuddyReminder.pending).not_to include(reminder)
      end

      it "follows it without being asked, because saving an occurrence announces it" do
        reminder = remind("agenda:interview-30m")
        reminder.save!

        expect { anchor.set_occurrence(noon + 1.hour, identifier: "1289") }
          .to change { reminder.reload.fire_at }.to(be_within(1.second).of(noon + 30.minutes))
      end

      it "counts what it moved, for a row that went stale another way" do
        reminder = remind("agenda:interview-30m")
        reminder.save!
        reminder.update_columns(fire_at: noon) # rubocop:disable Rails/SkipsModelValidations

        expect(anchor.propagate!).to include(reminders: 1)
      end
    end
  end
end
