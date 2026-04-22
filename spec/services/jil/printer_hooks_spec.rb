RSpec.describe "Printer hooks task" do
  let(:user) { User.me }

  let(:hooks_code) { <<~'JIL'.strip }
    *input = Global.input_data()::Hash
    *topic = input.get("topic")::String
    *message = input.get("message")::String
    *device = input.get("deviceIdentifier")::String
    *extra = input.get("extra")::Hash
    state_data = input.get("state")::Hash
    state_type = Global.looksLike(state_data)::String
    is_state_hash = state_type.match("Hash")::Boolean
    *state_text = Global.if({
      sh1 = Global.ref(is_state_hash)::Boolean
    }, {
      sh2 = state_data.get("text")::String
    }, {
      sh3 = String.new("")::String
    })::String
    *state_error = Global.if({
      se1 = Global.ref(is_state_hash)::Boolean
    }, {
      se2 = state_data.get("error")::String
    }, {
      se3 = String.new("")::String
    })::String
    flags_raw = Global.if({
      fl1 = Global.ref(is_state_hash)::Boolean
    }, {
      fl2 = state_data.get("flags")::Hash
    }, {
      fl3 = Hash.new({})::Hash
    })::Hash
    active_flags = flags_raw.map({
      fg1 = Global.if({
        fg2 = Keyword.Value()::Boolean
      }, {
        fg3 = Keyword.Key()::String
      }, {})::Any
    })::Array
    *activeFlags = active_flags.compact()::Array
    *job = input.get("job")::Hash
    *progress = input.get("progress")::Hash
    meta = input.get("meta")::Hash
    meta_type = Global.looksLike(meta)::String
    is_meta_hash = meta_type.match("Hash")::Boolean
    *estimatedPrintTime = Global.if({
      mh1 = Global.ref(is_meta_hash)::Boolean
    }, {
      mh2 = meta.dig({
        mh3 = String.new("analysis")::String
        mh4 = String.new("estimatedPrintTime")::String
      })::Numeric
    }, {
      mh5 = Numeric.new(0)::Numeric
    })::Numeric
    printer_state = Hash.new({
      ps1 = Keyval.new("state", state_text)::Keyval
      ps2 = Keyval.new("error", state_error)::Keyval
      ps3 = Keyval.new("flags", activeFlags)::Keyval
      ps4 = Keyval.new("topic", topic)::Keyval
      ps5 = Keyval.new("message", message)::Keyval
      ps6 = Keyval.new("device", device)::Keyval
    })::Hash
    ps7 = Global.set_cache("printer", "printer_state", printer_state)::Any
    print_data = Hash.new({
      pd1 = Keyval.new("state", state_text)::Keyval
      pd2 = Keyval.new("error", state_error)::Keyval
      pd3 = Keyval.new("activeFlags", activeFlags)::Keyval
      pd4 = Keyval.new("topic", topic)::Keyval
      pd5 = Keyval.new("message", message)::Keyval
      pd6 = Keyval.new("device", device)::Keyval
      pd7 = Keyval.new("extra", extra)::Keyval
      pd8 = Keyval.new("job", job)::Keyval
      pd9 = Keyval.new("progress", progress)::Keyval
      pda = Keyval.new("estimatedPrintTime", estimatedPrintTime)::Keyval
    })::Hash
    pdb = Global.set_cache("print", "current", print_data)::Hash
    flagGroup = activeFlags.join("-")::String
    pdc = Global.set_cache("print", flagGroup, print_data)::Hash
  JIL

  before { user.action_events.destroy_all }

  describe "validation" do
    it "passes Jil::Validator" do
      Jil::Validator.validate!(hooks_code)
    end
  end

  describe "execution" do
    it "handles normal print progress data" do
      executor = Jil::Executor.call(user, hooks_code, {
        topic: "Print Progress",
        message: "50% complete",
        deviceIdentifier: "zoro-pi-1",
        state: { text: "Printing", error: "", flags: { operational: true, printing: true } },
        job: { file: { display: "Test-1H.gcode" } },
        progress: { completion: 50, printTime: 1800 },
        meta: { analysis: { estimatedPrintTime: 3600 } },
      })
      expect(executor.ctx[:error]).to be_blank
    end

    it "handles custom event with null job data and string meta" do
      executor = Jil::Executor.call(user, hooks_code, {
        topic: "Custom Event",
        message: "Printing Began",
        deviceIdentifier: "zoro-pi-1",
        state: { text: "Operational", error: "", flags: { operational: true, ready: true } },
        job: { file: { name: nil, display: nil }, filament: nil, estimatedPrintTime: nil },
        progress: { printTime: nil, completion: nil },
        meta: "",
        extra: { cmd: "M117 print_started", gcode: "M117" },
      })
      expect(executor.ctx[:error]).to be_blank
    end

    it "handles error/offline with closedOrError flag" do
      executor = Jil::Executor.call(user, hooks_code, {
        topic: "Error",
        message: "There was an error.",
        deviceIdentifier: "zoro-pi-1",
        state: { text: "Offline after error", error: "Connection failed", flags: { closedOrError: true } },
        job: { file: { name: nil }, filament: nil, estimatedPrintTime: nil },
        progress: { printTime: nil, completion: nil },
        meta: "",
        extra: { error: "Connection failed", reason: "autodetect" },
      })
      expect(executor.ctx[:error]).to be_blank

      # Printer state stored separately
      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("printer_state", "state")).to eq("Offline after error")
      expect(cache.dig("printer_state", "error")).to eq("Connection failed")
    end

    it "handles completely missing state/meta" do
      executor = Jil::Executor.call(user, hooks_code, {
        topic: "Something",
        deviceIdentifier: "zoro-pi-1",
      })
      expect(executor.ctx[:error]).to be_blank
    end
  end
end
