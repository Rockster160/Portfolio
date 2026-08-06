require "rails_helper"

# Byte wiring a pairing itself, so "logging coffee should tick off the coffee
# chore" doesn't need somebody to open the Jil editor.
RSpec.describe "Buddy record link tools" do
  let(:user)      { User.me }
  let(:household) { user.chore_household }

  def ctx = Buddy::ToolContext.new(user)

  def run(name, payload)
    tool = Buddy::Tools[name]
    confirm = tool[:confirm].call(payload, ctx)
    [tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx), confirm]
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    RecordLink.delete_all
    Chore.where(chore_household: household).delete_all
    Chore.create!(chore_household: household, created_by_user: user, name: "Coffee Run")
  end

  describe "link_records" do
    it "wires an event to a chore" do
      result, confirm = run(:link_records, {
        source:      :event,
        source_name: "Coffee",
        target:      :chore,
        target_name: "Coffee Run",
      })

      expect(confirm[:summary]).to include("Coffee Run")
      expect(result[:verb]).to eq("Linked")
      link = RecordLink.last
      expect(link.source_event?).to be(true)
      expect(link.target_chore?).to be(true)
    end

    it "wires a chore to a list item" do
      run(:link_records, {
        source:      :chore,
        source_name: "Coffee Run",
        target:      :list_item,
        target_name: "Beans",
        target_list: "Shopping",
      })

      expect(RecordLink.last.target_scope).to eq("Shopping")
    end

    # The cascade is the whole design. Asking for one of these should be met
    # with "that runs the wrong way", not a link that silently never fires.
    it "refuses a chore writing an event" do
      expect {
        run(:link_records, { source: :chore, source_name: "Coffee Run", target: :event, target_name: "Coffee" })
      }.to raise_error(/runs event -> chore -> agenda -> list_item/)
    end

    it "refuses a list item touching a chore" do
      expect {
        run(:link_records, { source: :list_item, source_name: "Beans", target: :chore, target_name: "Coffee Run" })
      }.to raise_error(/runs event/)
    end

    it "resolves a fuzzily-named chore to the real record" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "coffee run" })

      expect(RecordLink.last.target_name).to eq("Coffee Run")
    end

    # An event name is whatever gets typed at log time and may not exist yet, so
    # there's nothing to resolve it against — guessing would be inventing.
    it "stores an event name exactly as given" do
      run(:link_records, { source: :event, source_name: "d-amphetamine", target: :chore, target_name: "Coffee Run" })

      expect(RecordLink.last.source_name).to eq("d-amphetamine")
    end

    it "puts a loose match on the notes when notes are given" do
      run(:link_records, {
        source:       :event,
        source_name:  "M",
        source_notes: "Duloxetine",
        target:       :chore,
        target_name:  "Coffee Run",
        match:        :contains,
      })

      link = RecordLink.last
      expect(link.source_scope_match).to eq("contains")
      expect(link.source_name_match).to eq("exactly")
    end

    it "puts a loose match on the name when there are no notes" do
      run(:link_records, {
        source:      :event,
        source_name: "D-Amphetamine",
        target:      :chore,
        target_name: "Coffee Run",
        match:       :starts_with,
      })

      link = RecordLink.last
      expect(link.source_name_match).to eq("starts_with")
      expect(link.source_scope_match).to eq("exactly")
    end

    it "defaults to an exact match" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })

      expect(RecordLink.last.source_name_match).to eq("exactly")
    end

    it "refuses a list pairing that doesn't say which list" do
      expect {
        run(:link_records, { source: :chore, source_name: "Coffee Run", target: :list_item, target_name: "Beans" })
      }.to raise_error(/which list/)
    end

    it "sets ask_who only where it means something" do
      run(:link_records, {
        source:      :event,
        source_name: "Fae",
        target:      :chore,
        target_name: "Coffee Run",
        ask_who:     true,
      })
      expect(RecordLink.last).to be_ask_who

      run(:link_records, {
        source:      :chore,
        source_name: "Coffee Run",
        target:      :list_item,
        target_name: "Beans",
        target_list: "Shopping",
        ask_who:     true,
      })
      expect(RecordLink.last).not_to be_ask_who
    end

    it "updates an existing pairing rather than making a second one" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })

      result, = run(:link_records, {
        source:      :event,
        source_name: "Coffee",
        target:      :chore,
        target_name: "Coffee Run",
        match:       :contains,
      })

      expect(result[:verb]).to eq("Updated")
      expect(RecordLink.count).to eq(1)
      expect(RecordLink.last.source_name_match).to eq("contains")
    end

    it "hands back an undo" do
      result, = run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })

      expect(Buddy::Reverter.reversible?(result[:revert])).to be(true)
      Buddy::Reverter.call(result[:revert])
      expect(RecordLink.count).to eq(0)
    end

    it "hands back an undo that restores the old match on an update" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })
      result, = run(:link_records, {
        source:      :event,
        source_name: "Coffee",
        target:      :chore,
        target_name: "Coffee Run",
        match:       :contains,
      })

      Buddy::Reverter.call(result[:revert])

      expect(RecordLink.last.source_name_match).to eq("exactly")
    end

    it "describes what it did in a sentence" do
      result, = run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })

      expect(result[:summary]).to eq('logged event where name is exactly "Coffee" completes chore "Coffee Run"')
    end
  end

  describe "unlink_records" do
    it "breaks the pairing, named from either end" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })

      run(:unlink_records, { name: "Coffee Run" })

      expect(RecordLink.count).to eq(0)
    end

    it "finds it by the source end too" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })

      run(:unlink_records, { name: "Coffee" })

      expect(RecordLink.count).to eq(0)
    end

    # Silently unlinking the first of three is worse than asking.
    it "names the options rather than guessing when an end is in several" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })
      run(:link_records, {
        source:      :chore,
        source_name: "Coffee Run",
        target:      :list_item,
        target_name: "Beans",
        target_list: "Shopping",
      })

      expect { run(:unlink_records, { name: "Coffee Run" }) }.to raise_error(/2 pairings.*say which/m)
    end

    it "takes the far end to disambiguate" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })
      run(:link_records, {
        source:      :chore,
        source_name: "Coffee Run",
        target:      :list_item,
        target_name: "Beans",
        target_list: "Shopping",
      })

      run(:unlink_records, { name: "Coffee Run", other: "Beans" })

      expect(RecordLink.count).to eq(1)
      expect(RecordLink.last.source_name).to eq("Coffee")
    end

    it "says so when nothing is linked" do
      expect { run(:unlink_records, { name: "Coffee Run" }) }.to raise_error(/nothing is linked/)
    end

    it "hands back an undo that puts the pairing back" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })
      result = run(:unlink_records, { name: "Coffee Run" }).first

      Buddy::Reverter.call(result[:revert])

      expect(RecordLink.count).to eq(1)
    end
  end

  describe "the context section" do
    it "shows the rule as a sentence" do
      run(:link_records, { source: :event, source_name: "Coffee", target: :chore, target_name: "Coffee Run" })
      convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      rows = Buddy::Context.full(user, convo)[:record_links]

      expect(rows.first[:does]).to include("completes chore \"Coffee Run\"")
      expect(Buddy::GPT::ContextTool::SECTIONS).to include(:record_links)
    end

    it "flags an end that points at nothing" do
      run(:link_records, {
        source:      :chore,
        source_name: "Coffee Run",
        target:      :list_item,
        target_name: "Beans",
        target_list: "No Such List",
      })
      convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      rows = Buddy::Context.full(user, convo)[:record_links]

      expect(rows.first[:broken].join).to include("No Such List")
    end

    it "teaches the model the cascade direction" do
      prompt = Buddy::Personality.for(user, conversation: user.byte_conversations.create!(mode: :buddy))

      expect(prompt).to include("These only ever run downhill")
      expect(prompt).to include("logged event → chore → agenda task → list item")
      expect(prompt).to include("when something happened that they didn't do")
    end
  end
end
