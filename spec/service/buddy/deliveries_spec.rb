require "rails_helper"

# Prod 2604: "Can you see my Amazon orders?" got "Nope, not from here." It could
# have — AmazonOrder has held the list for ages, rebuilt from the shipping
# emails that land in the inbox. There was just no tool pointed at it.
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
    it "lists what's coming, soonest first" do
      stock!([
        { name: "Light Sockets", on: today + 1 },
        { name: "Wrist White Board", on: today },
      ])

      rows = described_class.call(user: owner)[:rows]
      expect(rows.first).to start_with("Wrist White Board · due today")
      expect(rows.last).to start_with("Light Sockets · due tomorrow")
    end

    it "carries the carrier, the tracking number and the price through" do
      stock!([{ name: "Desk", on: today, carrier: "ups", tracking: "1Z999", amount: 20.4 }])

      expect(described_class.call(user: owner)[:rows].first)
        .to include("ups 1Z999").and include("$20.40")
    end

    # A date that's been and gone with nothing confirming it is exactly what
    # somebody is asking about, so it can't fall out of the window.
    it "keeps an overdue package in the list and says the date passed" do
      stock!([{ name: "Mattress", on: today - 3 }])

      expect(described_class.call(user: owner)[:rows].first).to include("was due")
    end

    it "reads a delivered one as arrived rather than overdue" do
      stock!([{ name: "Mattress", on: today - 1, delivered: true }])

      expect(described_class.call(user: owner)[:rows].first).to include("arrived yesterday")
    end

    it "drops an arrival old enough to be history" do
      stock!([{ name: "Mattress", on: today - 30, delivered: true }])

      expect(described_class.call(user: owner)[:rows]).to be_empty
    end

    it "leaves out what's further off than they asked" do
      stock!([{ name: "Sofa", on: today + 40 }])

      expect(described_class.call(user: owner, days: 14)[:rows]).to be_empty
      expect(described_class.call(user: owner, days: 60)[:rows].length).to eq(1)
    end

    it "keeps a package that never got a date" do
      stock!([{ name: "Mystery box", on: nil }])

      expect(described_class.call(user: owner)[:rows].first).to include("no date on it")
    end

    describe "matching how they'd say it" do
      before {
        stock!([
          { name: "Wrist White Board", on: today },
          { name: "Computer Desk", on: today + 1, carrier: "ups", tracking: "1Z999" },
        ])
      }

      it "matches on words in any order" do
        expect(described_class.call(user: owner, query: "desk computer")[:rows].length).to eq(1)
      end

      it "matches a tracking number" do
        expect(described_class.call(user: owner, query: "1Z999")[:rows].first).to include("Computer Desk")
      end

      it "falls back to the words that do land" do
        expect(described_class.call(user: owner, query: "that desk thing")[:rows].first)
          .to include("Computer Desk")
      end

      it "comes back empty for something that isn't there" do
        expect(described_class.call(user: owner, query: "kayak")[:rows]).to be_empty
      end
    end
  end

  # MeCache is the OWNER's cache. There is no per-user delivery list to fall
  # back to, so anyone else asking must get nothing rather than his packages.
  describe "whose list it is" do
    it "answers for the owner" do
      expect(described_class.available?(owner)).to be(true)
    end

    it "refuses anyone else, whatever the feature flag says" do
      stock!([{ name: "Wrist White Board", on: today }])

      expect(described_class.available?(other)).to be(false)
      expect(described_class.call(user: other)[:rows]).to be_empty
      expect { described_class.add!(user: other, name: "x") }.to raise_error(/aren't part of/)
      expect { described_class.arrived!(user: other, match: "x") }.to raise_error(/aren't part of/)
    end

    it "keeps the tools off everyone else's schema" do
      expect(Buddy::Features::DEFAULT).not_to include(:deliveries)
      %i[check_deliveries track_delivery delivery_arrived].each do |name|
        expect(Buddy::Features.allows_tool?(other, Buddy::Tools[name])).to be(false)
      end
    end
  end

  describe ".add!" do
    it "puts a hand-added package on the list for the day they said" do
      described_class.add!(user: owner, name: "Computer Desk", on: today + 2, tracking: "283588")

      row = described_class.call(user: owner)[:rows].first
      expect(row).to include("Computer Desk")
      expect(AmazonOrder.reload.first.tracking_number).to eq("283588")
    end

    it "lands it on today when they didn't say" do
      described_class.add!(user: owner, name: "Mystery")

      expect(described_class.call(user: owner)[:rows].first).to include("due today")
    end

    it "marks it manual so it doesn't pretend to be an Amazon row" do
      described_class.add!(user: owner, name: "Computer Desk")

      expect(AmazonOrder.reload.first.carrier).to eq(:manual)
    end

    it "refuses a nameless one" do
      expect { described_class.add!(user: owner, name: "  ") }.to raise_error(/needs a name/)
    end

    # The dashboard redraws off the broadcast; without it the page keeps showing
    # a list that no longer matches what Buddy just said it did.
    it "tells the dashboard" do
      described_class.add!(user: owner, name: "Computer Desk")

      expect(ActionCable.server).to have_received(:broadcast).with(:amz_updates_channel, anything)
    end
  end

  # The dashboard can already do all of this, but only through a typed command
  # with an inline `{ url: "…" }` block on the end — a syntax to remember
  # rather than a thing to say.
  describe ".edit!" do
    before { stock!([{ name: "Office item", on: today + 2, carrier: "amazon", tracking: "1Z999" }]) }

    # The usual one: an email named the row off its category.
    it "renames a row the email guessed at" do
      described_class.edit!(user: owner, match: "office", name: "Wrist White Board")

      expect(described_class.call(user: owner)[:rows].first).to include("Wrist White Board")
    end

    it "moves the day" do
      described_class.edit!(user: owner, match: "office", on: today)

      expect(described_class.call(user: owner)[:rows].first).to include("due today")
    end

    # A rename must not quietly drop everything it didn't mention.
    it "leaves the fields it wasn't given alone" do
      described_class.edit!(user: owner, match: "office", name: "Wrist White Board")

      order = AmazonOrder.reload.first
      expect(order.tracking_number).to eq("1Z999")
      expect(order.delivery_date).to eq((today + 2).iso8601)
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

    it "tells the model an empty list means no email came, not that nothing was ordered" do
      expect(read[:how]).to include("no email has come in")
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
      expect(result[:error]).to include("nothing to change")
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

    it "refuses a day it can't read rather than quietly using today" do
      result = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:track_delivery],
        { call_id: "c1", name: :track_delivery, arguments: { name: "Desk", when: "whenever" } },
        user: owner, conversation: nil,
      )
      expect(result[:status]).to eq("failed")
      expect(result[:error]).to include("couldn't read")
    end
  end
end
