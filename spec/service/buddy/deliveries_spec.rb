require "rails_helper"

# The owner's package list (AmazonOrder, rebuilt from shipping emails), as
# Buddy reads and edits it.
RSpec.describe Buddy::Deliveries do
  let(:owner) { User.me }
  let(:other) { create(:user) }
  let(:today) { owner.perceived_today }
  let(:convo) { owner.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }
  let(:msg)   { convo.byte_messages.create!(user: owner, direction: :inbound, state: :delivered, body: "ok") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    # Granted rather than assumed, like `mac` — see Buddy::Features::OWNER_ONLY.
    owner.update!(buddy_features: (owner.buddy_features + ["deliveries"]).uniq)
    MeCache.set(:amazon_deliveries, [])
    AmazonOrder.clear
  end

  def stock!(rows)
    MeCache.set(:amazon_deliveries, rows.map { |r|
      {
        order_id:        r[:order_id] || "CUSTOM",
        item_id:         r[:item_id] || "CUSTOM-#{SecureRandom.hex(2)}",
        name:            r[:name],
        delivery_date:   r[:on]&.iso8601,
        delivered:       r[:delivered],
        carrier:         r[:carrier] || "amazon",
        tracking_number: r[:tracking],
        amount:          r[:amount],
        email_ids:       [],
        errors:          [],
      }.stringify_keys
    })
    AmazonOrder.clear
  end

  describe ".call" do
    # An overdue package with nothing confirming it is exactly what somebody is
    # asking about, so it can't fall out of the window.
    it "lists soonest first with each package's state, carrier, tracking and price", :aggregate_failures do
      stock!([
        { name: "Light Sockets", on: today + 1 },
        { name: "Wrist White Board", on: today, carrier: "ups", tracking: "1Z999", amount: 20.4 },
        { name: "Overdue Mattress", on: today - 3 },
        { name: "Arrived Lamp", on: today - 1, delivered: true },
        { name: "Old Rug", on: today - 30, delivered: true },
        { name: "Mystery box", on: nil },
      ])

      rows = described_class.call(user: owner)[:rows]
      by_name = rows.index_by { |r| r.split(" · ").first }

      expect(rows.index(by_name["Wrist White Board"])).to be < rows.index(by_name["Light Sockets"])
      expect(by_name["Wrist White Board"]).to include("due today", "ups 1Z999", "$20.40")
      expect(by_name["Light Sockets"]).to include("due tomorrow")
      expect(by_name["Overdue Mattress"]).to include("was due")
      expect(by_name["Arrived Lamp"]).to include("arrived yesterday")
      expect(by_name["Mystery box"]).to include("no date on it")
      expect(by_name).not_to have_key("Old Rug")
    end

    it "leaves out what's further off than they asked" do
      stock!([{ name: "Sofa", on: today + 40 }])

      expect(described_class.call(user: owner, days: 14)[:rows]).to be_empty
      expect(described_class.call(user: owner, days: 60)[:rows].length).to eq(1)
    end

    describe "matching how they'd say it" do
      before {
        stock!([
          { name: "Wrist White Board", on: today },
          { name: "Computer Desk", on: today + 1, carrier: "ups", tracking: "1Z999" },
        ])
      }

      it "matches words in any order, a tracking number, or the words that land, and nothing else" do
        expect(described_class.call(user: owner, query: "desk computer")[:rows].length).to eq(1)
        expect(described_class.call(user: owner, query: "1Z999")[:rows].first).to include("Computer Desk")
        expect(described_class.call(user: owner, query: "that desk thing")[:rows].first).to include("Computer Desk")
        expect(described_class.call(user: owner, query: "kayak")[:rows]).to be_empty
      end
    end
  end

  # MeCache is the OWNER's cache. There is no per-user delivery list to fall
  # back to, so anyone else asking must get nothing rather than his packages.
  describe "whose list it is" do
    it "answers for the owner and refuses anyone else, whatever the feature flag says" do
      stock!([{ name: "Wrist White Board", on: today }])

      expect(described_class.available?(owner)).to be(true)
      expect(described_class.available?(other)).to be(false)
      expect(described_class.call(user: other)[:rows]).to be_empty
      expect { described_class.add!(user: other, name: "x") }.to raise_error(/aren't part of/)
      expect { described_class.arrived!(user: other, match: "x") }.to raise_error(/aren't part of/)
    end

    it "keeps the tools off everyone else's schema" do
      %i[check_deliveries track_delivery delivery_arrived].each do |name|
        expect(Buddy::Features.allows_tool?(other, Buddy::Tools[name])).to be(false)
      end
    end
  end

  describe ".add!" do
    it "puts a hand-added package on the list, marked manual, and tells the dashboard" do
      described_class.add!(user: owner, name: "Computer Desk", on: today + 2, tracking: "283588")

      order = AmazonOrder.reload.first
      expect(described_class.call(user: owner)[:rows].first).to include("Computer Desk")
      expect(order.tracking_number).to eq("283588")
      expect(order.delivery_date).to eq((today + 2).iso8601)
      expect(order.carrier).to eq(:manual)
      expect(ActionCable.server).to have_received(:broadcast).with(:amz_updates_channel, anything)
    end

    it "lands it on today when they didn't say" do
      described_class.add!(user: owner, name: "Mystery")

      expect(described_class.call(user: owner)[:rows].first).to include("due today")
    end

    it "takes a carrier when they named one, so the tracking number links" do
      described_class.add!(user: owner, name: "Computer Desk", tracking: "532572111399", carrier: :fedex)

      order = AmazonOrder.reload.first
      expect(order.carrier).to eq(:fedex)
      expect(order.url).to eq("https://www.fedex.com/fedextrack/?trknbr=532572111399")
    end

    it "refuses a nameless one" do
      expect { described_class.add!(user: owner, name: "  ") }.to raise_error(/needs a name/)
    end
  end

  describe ".edit!" do
    before { stock!([{ name: "Office item", on: today + 2, carrier: "amazon", tracking: "1Z999" }]) }

    # A rename must not quietly drop everything it didn't mention.
    it "renames a row and leaves the fields it wasn't given alone" do
      described_class.edit!(user: owner, match: "office", name: "Wrist White Board")

      order = AmazonOrder.reload.first
      expect(described_class.call(user: owner)[:rows].first).to include("Wrist White Board")
      expect(order.tracking_number).to eq("1Z999")
      expect(order.delivery_date).to eq((today + 2).iso8601)
    end

    it "moves the day" do
      described_class.edit!(user: owner, match: "office", on: today)

      expect(described_class.call(user: owner)[:rows].first).to include("due today")
    end

    it "attaches a tracking number that turned up later" do
      described_class.edit!(user: owner, match: "office", tracking: "283588", url: "https://x.test/o/1")

      order = AmazonOrder.reload.first
      expect(order.tracking_number).to eq("283588")
      expect(order.custom_url).to eq("https://x.test/o/1")
    end

    it "says so when nothing matches instead of editing the wrong package" do
      expect { described_class.edit!(user: owner, match: "kayak", name: "x") }
        .to raise_error(/nothing on the way matches/)
    end

    # Without the carrier the row has no CARRIER_TRACKING_URLS entry and the
    # tracking number can't become a link.
    it "takes the carrier alongside the number, the number becomes a link, and reads back" do
      described_class.edit!(user: owner, match: "office", tracking: "532572111399", carrier: :fedex)

      order = AmazonOrder.reload.first
      expect(order.carrier).to eq(:fedex)
      expect(order.url).to eq("https://www.fedex.com/fedextrack/?trknbr=532572111399")
      expect(described_class.call(user: owner)[:rows].first).to include("fedex 532572111399")
    end

    it "leaves the carrier alone when they didn't name one" do
      described_class.edit!(user: owner, match: "office", tracking: "532572111399")

      expect(AmazonOrder.reload.first.carrier).to eq(:amazon)
    end

    it "refuses anyone but the owner" do
      expect { described_class.edit!(user: other, match: "office", name: "x") }
        .to raise_error(/aren't part of/)
    end
  end

  describe ".arrived!" do
    it "marks the match, and keeps the row" do
      stock!([{ name: "Computer Desk", on: today }])

      described_class.arrived!(user: owner, match: "desk")

      expect(described_class.call(user: owner)[:rows].first).to include("arrived today")
    end

    # "The desk came" means the one still expected, not last month's under the
    # same name.
    it "prefers the one still on its way over one already marked" do
      stock!([
        { name: "Computer Desk", on: today - 2, delivered: true },
        { name: "Computer Desk", on: today, item_id: "CUSTOM-two" },
      ])

      described_class.arrived!(user: owner, match: "desk")

      expect(AmazonOrder.reload.select(&:delivered).length).to eq(2)
    end

    it "says so when nothing matches instead of guessing" do
      stock!([{ name: "Computer Desk", on: today }])

      expect { described_class.arrived!(user: owner, match: "kayak") }
        .to raise_error(/nothing on the way matches/)
    end
  end

  describe "the tools" do
    def read(payload={})
      Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:check_deliveries],
        { call_id: "c1", name: :check_deliveries, arguments: payload },
        user: owner, conversation: nil,
      )
    end

    it "answers in the same turn rather than leaving a row behind" do
      stock!([{ name: "Wrist White Board", on: today }])

      result = read
      expect(result[:status]).to eq(:answered)
      expect(result[:deliveries].first).to include("Wrist White Board")
    end

    it "refuses to guess which package when the name matches nothing" do
      stock!([{ name: "Computer Desk", on: today }])

      result = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:delivery_arrived],
        { call_id: "c1", name: :delivery_arrived, arguments: { match: "kayak" } },
        user: owner, conversation: nil,
      )
      expect(result[:status]).to eq("failed")
    end

    it "refuses an update that would change nothing" do
      stock!([{ name: "Computer Desk", on: today }])

      result = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:update_delivery],
        { call_id: "c1", name: :update_delivery, arguments: { match: "desk" } },
        user: owner, conversation: nil,
      )
      expect(result[:status]).to eq("failed")
    end

    it "reports a rename as a rename" do
      stock!([{ name: "Office item", on: today }])

      Buddy::ProposalBuilder.create(
        user: owner, byte_message: msg,
        markers: [{ tool_name: :update_delivery, payload: { match: "office", name: "Wrist White Board" }, span: [0, 0] }]
      )

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("Office item").and include("Wrist White Board")
    end

    it "carries the carrier through from what they said" do
      stock!([{ name: "Computer Desk", on: today }])

      Buddy::ProposalBuilder.create(
        user: owner, byte_message: msg,
        markers: [{ tool_name: :update_delivery,
                    payload: { match: "desk", tracking: "532572111399", carrier: :fedex }, span: [0, 0] }]
      )

      expect(AmazonOrder.reload.first.carrier).to eq(:fedex)
    end

    it "counts a carrier on its own as a change worth making" do
      stock!([{ name: "Computer Desk", on: today, carrier: "manual" }])

      Buddy::ProposalBuilder.create(
        user: owner, byte_message: msg,
        markers: [{ tool_name: :update_delivery, payload: { match: "desk", carrier: :fedex }, span: [0, 0] }]
      )

      expect(AmazonOrder.reload.first.carrier).to eq(:fedex)
    end

    it "refuses a carrier it has nowhere to send" do
      stock!([{ name: "Computer Desk", on: today }])

      result = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:update_delivery],
        { call_id: "c1", name: :update_delivery, arguments: { match: "desk", carrier: "dhl" } },
        user: owner, conversation: nil,
      )

      expect(result[:status]).to eq("failed")
    end

    it "refuses a day it can't read rather than quietly using today" do
      result = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:track_delivery],
        { call_id: "c1", name: :track_delivery, arguments: { name: "Desk", when: "whenever" } },
        user: owner, conversation: nil,
      )
      expect(result[:status]).to eq("failed")
    end
  end
end
