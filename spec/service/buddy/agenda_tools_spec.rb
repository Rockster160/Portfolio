require "rails_helper"

# Buddy putting things on, and moving things between, calendars.
#
# Built around prod 1201: "move it to the Ours agenda" produced an ADD, so the
# same Costco Run ended up on two calendars at 1:00 PM. edit_agenda_item had no
# way to name a calendar, so there was no correct call available.
RSpec.describe "Buddy agenda tools" do
  let(:user) { create(:user) }
  # User#ensure_default_agenda makes this one on save, so it is genuinely the
  # oldest — which is exactly the situation the default-calendar setting exists
  # to override, since a personal calendar always predates a shared one.
  let(:personal)  { user.agendas.order(:id).first }
  let!(:ours)     { create(:agenda, user: user, name: "Ours 💕") }
  let(:at)        { Time.current.tomorrow.change(hour: 13) }

  before {
    allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
  }

  def ctx
    Buddy::ToolContext.new(user)
  end

  def run(tool_name, payload)
    tool    = Buddy::Tools[tool_name]
    confirm = tool[:confirm].call(payload, ctx)
    [tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx), confirm]
  end

  def costco_on(agenda)
    agenda.agenda_items.create!(name: "Costco Run", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)
  end

  describe "edit_agenda_item moving between calendars" do
    it "moves the existing item instead of leaving a second one behind" do
      item = costco_on(personal)

      run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

      expect(item.reload.agenda_id).to eq(ours.id)
      expect(AgendaItem.where(name: "Costco Run").count).to eq(1)
    end

    it "puts it back on undo" do
      item = costco_on(personal)
      result, = run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

      expect(item.reload.agenda_id).to eq(ours.id)
      Buddy::Reverter.call(result[:revert])

      expect(item.reload.agenda_id).to eq(personal.id)
    end

    it "refuses a calendar name that matches nothing rather than picking one" do
      costco_on(personal)

      expect {
        run(:edit_agenda_item, { item: "Costco Run", calendar: "Nonexistent Calendar" })
      }.to raise_error(/no calendar named/)
    end

    it "shows where it is going on the confirm row" do
      costco_on(personal)
      tool    = Buddy::Tools[:edit_agenda_item]
      confirm = tool[:confirm].call({ item: "Costco Run", calendar: "Ours" }, ctx)
      label   = tool[:label].call({ item: "Costco Run" }.merge(confirm[:resolved]), ctx)

      expect(label[:sub]).to include("#{personal.name} → Ours 💕")
    end

    it "says it moved rather than updated" do
      costco_on(personal)
      tool = Buddy::Tools[:edit_agenda_item]
      result, = run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

      expect(tool[:receipt].call(result, ctx)).to eq("Moved Costco Run to Ours 💕 ✓")
    end

    it "still edits an item on a calendar shared to the person for editing" do
      partner = create(:user)
      shared  = create(:agenda, user: partner, name: "Theirs")
      shared.agenda_shares.create!(user: user, permission: :editor)
      item = shared.agenda_items.create!(name: "Costco Run", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)

      run(:edit_agenda_item, { item: "Costco Run", title: "Costco Trip" })

      expect(item.reload.name).to eq("Costco Trip")
    end
  end

  # The checklist row prefixes itself with what tapping it will do, and calling
  # a to-do an "Event" is wrong in the one word that says whether the thing
  # occupies a span of the day. add_agenda_item takes `kind` as an argument;
  # editing one doesn't change what it is, so there's no argument to read and
  # confirm has to carry it off the record.
  describe "telling the row whether it's a task or an event" do
    def task_on(agenda)
      agenda.agenda_items.create!(name: "Shower", start_at: at, kind: :task, status: :confirmed)
    end

    it "resolves the kind of the item being edited" do
      task_on(personal)

      _, confirm = run(:edit_agenda_item, { item: "Shower", title: "Long shower" })

      expect(confirm[:resolved][:kind]).to eq("task")
    end

    it "says event for one that is one" do
      costco_on(personal)

      _, confirm = run(:edit_agenda_item, { item: "Costco Run", title: "Costco Trip" })

      expect(confirm[:resolved][:kind]).to eq("event")
    end
  end

  # Level 2: it goes on the calendar the moment Byte proposes it, as a
  # pre-checked row that unchecks back off. Making them tap to confirm every add
  # was a toll on the common case — they'd already said what they wanted, and
  # putting something on a calendar is easy to see and easy to take back.
  describe "an add landing on its own" do
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    def propose!(title)
      msg = convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
      )
      Buddy::ProposalBuilder.create(
        user:         user,
        byte_message: msg,
        markers:      [{ tool_name: :add_agenda_item, payload: { title: title, at: at.iso8601, kind: "task" } }],
      )
    end

    it "is on the calendar without anyone tapping anything" do
      expect { propose!("Shower") }.to change { AgendaItem.where(name: "Shower").count }.by(1)
    end

    it "leaves a row that's already ticked, and can be unticked" do
      result = propose!("Shower")
      row    = result[:action].buttons.first

      expect(row["status"]).to eq("executed")
      expect(row["undoable"]).to be(true)
    end

    # The undo has to actually reach the item, or the pre-checked row is a
    # promise it can't keep.
    it "takes it back off when the row is unticked" do
      result = propose!("Shower")
      action = result[:action]

      Buddy::ProposalExecutor.undo!(action.id, action.buttons.first["id"])

      expect(AgendaItem.find_by(name: "Shower")).to be_cancelled
    end
  end

  describe "add_agenda_item when the thing already exists" do
    it "warns that this looks like a move so the model can switch tools" do
      costco_on(personal)
      tool    = Buddy::Tools[:add_agenda_item]
      confirm = tool[:confirm].call({ title: "Costco Run", at: at, calendar: "Ours" }, ctx)

      expect(confirm[:summary]).to include("already exists")
      expect(confirm[:summary]).to include("edit_agenda_item")
    end

    it "does not warn about an unrelated item at the same time" do
      personal.agenda_items.create!(name: "Dentist", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)
      tool    = Buddy::Tools[:add_agenda_item]
      confirm = tool[:confirm].call({ title: "Costco Run", at: at }, ctx)

      expect(confirm[:summary]).not_to include("already exists")
    end

    it "still adds, since two real errands can collide" do
      costco_on(personal)

      run(:add_agenda_item, { title: "Costco Run", at: at, calendar: "Ours" })

      expect(AgendaItem.where(name: "Costco Run").count).to eq(2)
    end
  end

  describe "the default calendar" do
    it "lands on the oldest writable calendar when nothing is chosen" do
      expect(ctx.resolve_writable_agenda(nil)).to eq(personal)
    end

    it "honors the person's choice once they set one" do
      AgendaPreference.for(user).update!(default_agenda_id: ours.id)

      expect(ctx.resolve_writable_agenda(nil)).to eq(ours)
    end

    it "falls back when the chosen calendar is gone" do
      pref = AgendaPreference.for(user)
      pref.update!(default_agenda_id: ours.id)
      ours.destroy

      expect(pref.reload.default_agenda_id).to be_nil
      expect(Buddy::ToolContext.new(user.reload).resolve_writable_agenda(nil)).to eq(personal)
    end

    it "refuses a calendar the person cannot add to" do
      stranger = create(:user)
      theirs   = create(:agenda, user: stranger, name: "Not Yours")
      pref     = AgendaPreference.for(user)
      pref.default_agenda_id = theirs.id

      expect(pref).not_to be_valid
      expect(pref.errors[:default_agenda_id].join).to include("calendar you can add to")
    end

    it "stops flagging the calendar on the confirm row once it IS the default" do
      AgendaPreference.for(user).update!(default_agenda_id: ours.id)
      tool    = Buddy::Tools[:add_agenda_item]
      confirm = tool[:confirm].call({ title: "Dentist", at: at, calendar: "Ours" }, ctx)

      expect(confirm[:resolved][:agenda_default]).to be(true)
    end
  end
end
