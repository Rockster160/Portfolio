require "rails_helper"

# A chore asked for now is a chore for now. `marked_due_at` is the "appears on
# Today" stamp (ChoreSerializer#today_visible?), and create_chore only set it
# when the model passed an explicit `due` — so "add calibrating the printer as a
# 5p chore" got a cheerful "it's on there" and landed on nothing: not the Today
# tab, not Buddy's pending list.
RSpec.describe "a new chore is due today" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo)     { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)        { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }
  let(:today)      { ChoreDay.current(user) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    user.update!(chore_household_id: household.id)
  end

  def create!(payload)
    Buddy::ProposalBuilder.create(
      user: user, byte_message: msg,
      markers: [{ tool_name: :create_chore, payload: payload, span: [0, 0] }]
    )
    Chore.order(:id).last
  end

  it "stamps a one-off for today without being asked" do
    chore = create!(name: "Calibrate printer")

    expect(chore.marked_due_at).to be_present
    expect(ChoreDay.current(user, at: chore.marked_due_at)).to eq(today)
  end

  it "still takes an explicit day over the default" do
    chore = create!(name: "Calibrate printer", due: (today + 3).iso8601)

    expect(ChoreDay.current(user, at: chore.marked_due_at)).to eq(today + 3)
  end

  # A schedule IS the user saying otherwise, and the stamp overrides the
  # schedule for Today — so defaulting one would demand mowing on a Wednesday.
  it "leaves a scheduled chore to its schedule" do
    chore = create!(name: "Mow the lawn", schedule: "every Sunday")

    expect(chore.recurrence).to be_present
    expect(chore.marked_due_at).to be_nil
  end

  it "still lets a scheduled chore be pinned to a day when they ask" do
    chore = create!(name: "Mow the lawn", schedule: "every Sunday", due: today.iso8601)

    expect(ChoreDay.current(user, at: chore.marked_due_at)).to eq(today)
  end

  # The other half. Buddy's buckets called ANY marked-due chore backlog, with no
  # look at the date, so the chore it had just stamped for today came back
  # described as overdue.
  describe "which list Buddy sees it on" do
    def buckets
      Buddy::Context.build(user, convo)
    end

    def chore!(marked_at:)
      household.chores.create!(
        created_by_user: user, name: "Calibrate printer", one_off: true, marked_due_at: marked_at,
      )
    end

    it "puts a chore stamped for today on the pending list, not the backlog" do
      chore!(marked_at: ChoreDay.starts_at(today, user) + 1.hour)

      expect(buckets[:chores_pending_today].pluck(:name)).to include("Calibrate printer")
      expect(buckets[:chores_overdue_backlog]).to be_empty
    end

    it "marks it as actually due today rather than merely existing" do
      chore!(marked_at: ChoreDay.starts_at(today, user) + 1.hour)

      expect(buckets[:chores_pending_today].first[:due_today]).to be(true)
    end

    it "still calls a stamp from before today a carryover" do
      chore!(marked_at: ChoreDay.starts_at(today - 4, user))

      expect(buckets[:chores_pending_today]).to be_empty
      expect(buckets[:chores_overdue_backlog].pluck(:name)).to include("Calibrate printer")
    end

    # Pre-scheduling a one-off for a specific day shouldn't clutter today.
    it "keeps a stamp for a later day off both lists" do
      chore!(marked_at: ChoreDay.starts_at(today + 3, user))

      expect(buckets[:chores_pending_today]).to be_empty
      expect(buckets[:chores_overdue_backlog]).to be_empty
    end
  end

  it "says on the row that it's for today" do
    result = Buddy::ProposalBuilder.create(
      user: user, byte_message: msg,
      markers: [{ tool_name: :create_chore, payload: { name: "Calibrate printer" }, span: [0, 0] }]
    )

    expect(result[:action].buttons.first["sublabel"].to_s).to include("due")
  end
end
