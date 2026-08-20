RSpec.describe Jil::Methods::Custom do
  let(:user) { User.me }

  def jil(code, input_data={})
    ::Jil::Executor.call(user, code, input_data)
  end

  # ── Named args passed to custom functions ──────────────────────

  describe "named args in function calls" do
    let!(:func_task) {
      user.tasks.create!(
        name: "TestNamedFunc",
        listener: "function()",
        enabled: true,
        code: <<-'JIL',
          result = Global.functionParams({
            c = Keyword.NamedArg("color")::String
            s = Keyword.NamedArg("size")::Numeric
          })::Array
          *out = Global.print("#{c} #{s}")::String
          ret = Global.return(out)::Any
        JIL
      )
    }

    after { func_task.destroy }

    it "passes named Keyword args as a hash to the function" do
      exe = jil(<<-'JIL')
        result = Custom.TestNamedFunc({
          a1 = Keyword.color("blue")::String
          a2 = Keyword.size(42)::Numeric
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("blue 42")
    end

    it "handles missing named args with type defaults" do
      exe = jil(<<-'JIL')
        result = Custom.TestNamedFunc({
          a1 = Keyword.color("red")::String
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("red 0")
    end

    it "handles all args missing" do
      exe = jil(<<-'JIL')
        result = Custom.TestNamedFunc({})::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(" 0")
    end
  end

  # ── Positional args still work ─────────────────────────────────

  describe "positional args in function calls" do
    let!(:func_task) {
      user.tasks.create!(
        name: "TestPosFunc",
        listener: "function()",
        enabled: true,
        code: <<-'JIL',
          result = Global.functionParams({
            a = Keyword.Item()::String
            b = Keyword.Item()::Numeric
          })::Array
          *out = Global.print("#{a} #{b}")::String
          ret = Global.return(out)::Any
        JIL
      )
    }

    after { func_task.destroy }

    it "passes positional args via params array" do
      exe = jil(<<-'JIL')
        result = Custom.TestPosFunc("hello", 99)::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("hello 99")
    end
  end

  # ── UPSPackage: the phone's `ups` trigger → the shipment parser ─

  describe "Custom.UPSPackage" do
    include ActiveSupport::Testing::TimeHelpers

    # Noon UTC → midday in Denver, so "delivering today" doesn't straddle the
    # UTC-midnight boundary.
    around { |ex| travel_to(DateTime.new(2026, 8, 12, 18, 0, 0)) { ex.run } }

    before do
      allow(user).to receive(:me?).and_return(true)
      AmazonOrder.clear
      allow(MeCache).to receive(:get).and_call_original
      allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
      allow(AmazonOrder).to receive(:save)
      allow(AmazonOrder).to receive(:broadcast)
    end

    let(:text) {
      "UPS: 1ZXH04590371184662 delivering today 5:45 PM - 7:45 PM. " \
      "Leave with neighbor: ups.com/su/WGcxWDU0. Deliver another day: " \
      "ups.com/su/dmZYeUE1.  Reply STOP to cancel msgs"
    }

    # What the deployed `ups` listener task runs, shape for shape.
    def ups_code
      <<~'JIL'
        input = Global.input_data()::Hash
        raw = input.get("ups")::String
        result = Custom.UPSPackage(raw)::Hash
      JIL
    end

    it "opens a delivery for a tracking-only text and returns it" do
      exe = jil(ups_code, { "ups" => text })

      expect(exe.ctx[:error]).to be_blank
      expect(AmazonOrder.all.length).to eq(1)

      item = AmazonOrder.all.first
      expect(item.carrier).to eq(:ups)
      expect(item.tracking_number).to eq("1ZXH04590371184662")
      # Nothing in the text names the sender, so the row lands under its
      # tracking number for the user to rename — that IS the outcome.
      expect(item.name).to eq("1ZXH04590371184662")
      expect(item.delivery_date).to eq("2026-08-12")
      expect(item.time_range).to eq("5-7PM")

      returned = exe.ctx.dig(:vars, :result, :value)
      expect(returned[:tracking_number]).to eq("1ZXH04590371184662")
      expect(returned[:url]).to eq("https://www.ups.com/track?tracknum=1ZXH04590371184662")
    end

    it "back-fills the existing delivery when the tracking number already matches" do
      existing = AmazonOrder.create(
        carrier: :manual, name: "Computer Desk",
        order_id: "CUSTOM", item_id: "CUSTOM-f4f9",
        tracking_number: "1ZXH04590371184662",
      )

      jil(ups_code, { "ups" => text })

      expect(AmazonOrder.all.length).to eq(1)
      expect(existing.name).to eq("Computer Desk")
      expect(existing.delivery_date).to eq("2026-08-12")
      expect(existing.time_range).to eq("5-7PM")
    end

    it "creates nothing for a digest text and returns nil" do
      digest = "UPS: You have 2 packages estimated for delivery today."
      exe = jil(ups_code, { "ups" => digest })

      expect(exe.ctx[:error]).to be_blank
      expect(AmazonOrder.all).to be_empty
    end

    it "does not touch User.me's deliveries for another user's task" do
      allow(user).to receive(:me?).and_return(false)

      exe = jil(ups_code, { "ups" => text })

      expect(AmazonOrder.all).to be_empty
      expect(exe.ctx[:error]).to be_present
    end
  end

  # ── WayfairPackage: the phone's `wayfair` trigger → the shipment parser ─

  describe "Custom.WayfairPackage" do
    include ActiveSupport::Testing::TimeHelpers

    around { |ex| travel_to(DateTime.new(2026, 8, 20, 18, 0, 0)) { ex.run } }

    before do
      allow(user).to receive(:me?).and_return(true)
      AmazonOrder.clear
      allow(MeCache).to receive(:get).and_call_original
      allow(MeCache).to receive(:get).with(:amazon_deliveries).and_return([])
      allow(AmazonOrder).to receive(:save)
      allow(AmazonOrder).to receive(:broadcast)
    end

    let(:text) {
      "Wayfair: Exciting news! Your order is out for delivery. " \
      "Track your desk here: https://www.wayfair.com/pXJxCqyzBM"
    }

    # What the deployed `wayfair` listener task runs, shape for shape.
    def wayfair_code
      <<~'JIL'
        input = Global.input_data()::Hash
        raw = input.get("wayfair")::String
        result = Custom.WayfairPackage(raw)::Hash
      JIL
    end

    it "opens a delivery named for the product and returns it" do
      exe = jil(wayfair_code, { "wayfair" => text })

      expect(exe.ctx[:error]).to be_blank
      expect(AmazonOrder.all.length).to eq(1)

      item = AmazonOrder.all.first
      expect(item.carrier).to eq(:wayfair)
      expect(item.name).to eq("desk")
      expect(item.source).to eq("Wayfair")
      expect(item.delivery_date).to eq("2026-08-20")

      returned = exe.ctx.dig(:vars, :result, :value)
      expect(returned[:custom_url]).to eq("https://www.wayfair.com/pXJxCqyzBM")
      # Nothing to send to a carrier tracking page — the short link is the link.
      expect(returned[:url]).to be_nil
    end

    it "creates nothing for a marketing text and returns nil" do
      promo = "Wayfair: Way Day starts now! Up to 70% off: https://www.wayfair.com/zzQ1Ab2Cd"
      exe = jil(wayfair_code, { "wayfair" => promo })

      expect(exe.ctx[:error]).to be_blank
      expect(AmazonOrder.all).to be_empty
    end

    it "does not touch User.me's deliveries for another user's task" do
      allow(user).to receive(:me?).and_return(false)

      exe = jil(wayfair_code, { "wayfair" => text })

      expect(AmazonOrder.all).to be_empty
      expect(exe.ctx[:error]).to be_present
    end
  end
end
