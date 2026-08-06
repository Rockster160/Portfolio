require "rails_helper"

# `delivery:action:created|updated|delivered|delayed`, so a Jil task can react
# to a package the way it reacts to a list item or a chore.
#
# AmazonOrder is a cache-backed PORO with no model callbacks, so this hangs off
# the one thing every writer goes through — AmazonOrder.save. That covers the
# email parsers, the dashboard channel and Buddy without any of them having to
# announce themselves.
RSpec.describe DeliveryEvents do
  let(:user) { User.me }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(::Jil).to receive(:trigger)
    MeCache.set(:amazon_deliveries, [])
    AmazonOrder.clear
  end

  def row(overrides={})
    {
      "order_id"        => "111-1",
      "item_id"         => "ASIN-1",
      "name"            => "Computer Desk",
      "delivery_date"   => "2026-08-06",
      "delivered"       => nil,
      "carrier"         => "amazon",
      "tracking_number" => nil,
      "amount"          => 20.4,
      "email_ids"       => [],
      "errors"          => [],
    }.merge(overrides)
  end

  def stock!(rows)
    MeCache.set(:amazon_deliveries, rows)
    AmazonOrder.clear
  end

  def fired
    calls = []
    allow(::Jil).to receive(:trigger) { |_u, scope, data| calls << [scope, data] }
    yield
    calls
  end

  describe "what it announces" do
    it "fires created for a row that wasn't there before" do
      calls = fired {
        AmazonOrder.reload
        AmazonOrder.create(order_id: "111-1", item_id: "ASIN-1").tap { |o|
          o.name = "Computer Desk"
          o.delivery_date = Date.parse("2026-08-06")
        }
        AmazonOrder.save
      }

      expect(calls.length).to eq(1)
      scope, data = calls.first
      expect(scope).to eq(:delivery)
      expect(data).to include("action" => "created", "name" => "Computer Desk")
    end

    it "fires delivered when the flag flips" do
      stock!([row])

      calls = fired {
        AmazonOrder.reload.first.delivered = true
        AmazonOrder.save
      }

      expect(calls.map { |pair| pair.last["action"] }).to eq(["delivered"])
    end

    it "fires delayed when the date slips, and says what it was" do
      stock!([row])

      calls = fired {
        AmazonOrder.reload.first.delivery_date = Date.parse("2026-08-09")
        AmazonOrder.save
      }

      _scope, data = calls.first
      expect(data).to include("action" => "delayed", "delivery_date" => "2026-08-09", "previous_date" => "2026-08-06")
    end

    # Earlier is good news, not a slip.
    it "calls a date moving earlier an ordinary update" do
      stock!([row])

      calls = fired {
        AmazonOrder.reload.first.delivery_date = Date.parse("2026-08-04")
        AmazonOrder.save
      }

      expect(calls.map { |pair| pair.last["action"] }).to eq(["updated"])
    end

    it "fires updated for a rename" do
      stock!([row])

      calls = fired {
        AmazonOrder.reload.first.name = "Standing Desk"
        AmazonOrder.save
      }

      expect(calls.map { |pair| pair.last["action"] }).to eq(["updated"])
    end

    # Arrived AND moved is one event, and it's the one that matters.
    it "announces an arrival once, not twice" do
      stock!([row])

      calls = fired {
        order = AmazonOrder.reload.first
        order.delivered = true
        order.delivery_date = Date.parse("2026-08-09")
        AmazonOrder.save
      }

      expect(calls.map { |pair| pair.last["action"] }).to eq(["delivered"])
    end
  end

  describe "what it stays quiet about" do
    it "says nothing when the save changed nothing" do
      stock!([row])

      calls = fired {
        AmazonOrder.reload
        AmazonOrder.save
      }

      expect(calls).to be_empty
    end

    # Re-parsing an email appends an id. That is not news about the package,
    # and firing on it would make the trigger useless to listen on.
    it "says nothing when only the bookkeeping moved" do
      stock!([row])

      calls = fired {
        AmazonOrder.reload.first.email_ids = [1, 2, 3]
        AmazonOrder.save
      }

      expect(calls).to be_empty
    end

    it "says nothing about a row that went away" do
      stock!([row, row("item_id" => "ASIN-2", "name" => "Light Sockets")])

      calls = fired {
        AmazonOrder.reload.last.destroy
        AmazonOrder.save
      }

      expect(calls).to be_empty
    end
  end

  # A trigger that blows up must not take the write with it — the row is
  # already saved by the time this runs.
  it "keeps the save when the trigger raises" do
    stock!([row])
    allow(::Jil).to receive(:trigger).and_raise("boom")

    AmazonOrder.reload.first.name = "Standing Desk"
    expect { AmazonOrder.save }.not_to raise_error
    expect(AmazonOrder.reload.first.name).to eq("Standing Desk")
  end

  it "is a scope a listener is allowed to name" do
    expect(Jil::ListenerMatch.known_scope?("delivery")).to be(true)
  end
end
