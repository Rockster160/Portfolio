require "rails_helper"

# Eve holds the `agenda` feature and shares no calendar with anyone — no
# AgendaShare row names her in either direction. So her companion's agenda
# tools have to be closed at both ends: nothing she adds can reach somebody
# else's calendar, and nothing of theirs can reach her.
#
# Every one of these paths derives its agenda-id list from the person
# (`editable_agendas`, `accessible_agendas`, `Agenda.where(user_id:)`), which
# is why this holds. That is easy to lose by hand-rolling one query, hence the
# spec: the guarantee is the point, not any single line of it.
RSpec.describe "Buddy agenda isolation between unshared households" do
  let(:eve)   { create(:user) }
  let(:rocco) { create(:user) }
  let(:hers)  { eve.agendas.order(:id).first }
  let(:his)   { rocco.agendas.order(:id).first }
  let!(:work) { create(:agenda, user: rocco, name: "Rocco Work") }
  let(:at)    { Time.current.tomorrow.change(hour: 13) }

  before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

  def run(tool_name, payload, as:)
    ctx     = Buddy::ToolContext.new(as)
    tool    = Buddy::Tools[tool_name]
    confirm = tool[:confirm].call(payload, ctx)
    [tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx), confirm]
  end

  it "shares nothing in either direction to begin with" do
    expect(AgendaShare.where(user: [eve, rocco])).to be_empty
    expect(eve.editable_agendas.pluck(:id)).to eq([hers.id])
    expect(eve.accessible_agendas.pluck(:id)).to eq([hers.id])
  end

  describe "writing" do
    it "puts an unaddressed item on her own calendar" do
      run(:add_agenda_item, { title: "Fish food", at: at.iso8601 }, as: eve)

      expect(AgendaItem.find_by(name: "Fish food").agenda_id).to eq(hers.id)
    end

    # `strict:` on the resolve. A name nobody has is a question, not a silent
    # landing on whatever calendar happened to be first (prod 4463).
    it "refuses a calendar she cannot write to rather than falling back" do
      expect {
        run(:add_agenda_item, { title: "Fish food", at: at.iso8601, calendar: "Rocco Work" }, as: eve)
      }.to raise_error(/no calendar named/)

      expect(AgendaItem.where(name: "Fish food")).to be_empty
    end

    it "refuses in the other direction too" do
      expect {
        run(:add_agenda_item, { title: "Standup", at: at.iso8601, calendar: hers.name }, as: rocco)
      }.to raise_error(/no calendar named/)
    end
  end

  # She holds the `agenda` feature, so the page is hers to be sent to - the
  # link is how "where do I change that" gets a real answer instead of
  # directions to a screen the companion cannot see.
  describe "the link to it" do
    it "offers her the agenda page" do
      names = Buddy::AppPages.for_user(eve).pluck(:name)

      expect(names).to include(:agenda)
      expect(Buddy::AppPages.for_user(eve).find { |p| p[:name] == :agenda }[:url]).to end_with("/agenda")
    end

    # The reject has been in `for_user` from the start and only `interviews`
    # ever used it, so somebody without `chores` was handed the chore grid, the
    # pebble balance and the completion history - three links to pages that can
    # only be empty for them.
    it "keeps back the pages behind a feature she does not hold" do
      eve.update!(buddy_features: %w[agenda lists])
      names = Buddy::AppPages.for_user(eve).pluck(:name)

      expect(names).to include(:agenda, :lists)
      expect(names).not_to include(:chores, :chores_balance, :chores_history, :jil_tasks, :prompts)
    end

    it "still keeps the owner's own page to the owner" do
      expect(Buddy::AppPages.for_user(rocco).pluck(:name)).not_to include(:system)
      expect(Buddy::AppPages.for_user(User.me).pluck(:name)).to include(:system)
    end
  end

  describe "reading and editing" do
    let!(:his_item) { work.agenda_items.create!(name: "Payroll review", start_at: at, end_at: at + 1.hour, kind: :event, status: :confirmed) }
    let!(:her_item) { hers.agenda_items.create!(name: "Fish food", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed) }

    it "cannot edit an item on a calendar she has no share in" do
      expect { run(:edit_agenda_item, { item: "Payroll review", at: (at + 1.day).iso8601 }, as: eve) }.to raise_error(/.+/)

      expect(his_item.reload.start_at).to be_within(1.second).of(at)
    end

    it "cannot move one of his onto hers" do
      expect { run(:edit_agenda_item, { item: "Payroll review", calendar: hers.name }, as: eve) }.to raise_error(/.+/)

      expect(his_item.reload.agenda_id).to eq(work.id)
    end

    it "does not surface his items in her search" do
      found = Buddy::AgendaSearch.call(user: eve, query: "payroll", direction: :any)

      expect(found[:items]).to be_empty
      expect(Buddy::AgendaSearch.call(user: eve, query: "fish", direction: :any)[:items]).to be_present
    end

    it "does not surface his items in her agenda context" do
      ids = Buddy::Context.agenda_source_map(eve).keys

      expect(ids).to eq([hers.id])
    end

    # The bridge that turns "remind me at the plunge" into coordinates reads
    # agenda items by name, and it is the one that reads them OWN-ONLY rather
    # than through a share.
    it "does not resolve a place off somebody else's calendar" do
      work.agenda_items.create!(
        name: "Payroll review", start_at: at + 1.week, end_at: at + 1.week + 1.hour,
        kind: :event, status: :confirmed, location: "1 Ledger Lane"
      )

      expect(Buddy::ToolContext.new(eve).send(:agenda_location_for, "Payroll review")).to be_nil
    end
  end
end
