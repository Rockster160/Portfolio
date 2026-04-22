RSpec.describe "Filament set clears current when not printing" do
  let(:user) { User.me }

  # The shared logic for clearing current when setting filament on a non-printing state
  let(:set_clear_code) { <<~'JIL'.strip }
    input = Global.input_data()::Hash
    fil_name = input.get("fil_name")::String
    fil_color = input.get("fil_color")::String
    set_cur = Global.get_cache("printer", "current")::Hash
    cur_status = set_cur.get("status")::String
    is_printing = cur_status.match("printing")::Boolean
    x1 = Global.if({
      x2 = Global.ref(is_printing)::Boolean
    }, {
      x3 = set_cur.set!("filament_name", fil_name)::Hash
      x4 = set_cur.set!("filament_color", fil_color)::Hash
      x5 = Global.set_cache("printer", "current", set_cur)::Any
    }, {
      idle_cur = Hash.new({
        ic1 = Keyval.new("status", "idle")::Keyval
        ic2 = Keyval.new("filament_name", fil_name)::Keyval
        ic3 = Keyval.new("filament_color", fil_color)::Keyval
      })::Hash
      x6 = Global.set_cache("printer", "current", idle_cur)::Any
    })::Any
  JIL

  before do
    user.action_events.destroy_all
  end

  it "validates" do
    Jil::Validator.validate!(set_clear_code)
  end

  it "clears current when print is complete" do
    user.caches.by(:printer).update!(data: {
      current: {
        status: "complete", print_name: "OldPrint", event_id: 123,
        filament_name: "Red PLA", filament_color: "#FF0000",
        elapsed_sec: 3600, est_sec: 3600, actual_duration: 3600,
      },
      filaments: { "Blue PETG": { color: "#0000FF" } },
      active_filament: "Blue PETG",
    })

    Jil::Executor.call(user, set_clear_code, { fil_name: "Blue PETG", fil_color: "#0000FF" })

    cache = user.caches.by(:printer)
    cache.reload
    expect(cache.dig("current", "status")).to eq("idle")
    expect(cache.dig("current", "filament_name")).to eq("Blue PETG")
    expect(cache.dig("current", "filament_color")).to eq("#0000FF")
    expect(cache.dig("current", "print_name")).to be_nil
    expect(cache.dig("current", "event_id")).to be_nil
  end

  it "keeps current when print is active" do
    user.caches.by(:printer).update!(data: {
      current: {
        status: "printing", print_name: "ActivePrint", event_id: 456,
        filament_name: "Red PLA", filament_color: "#FF0000",
      },
      filaments: { "Blue PETG": { color: "#0000FF" } },
      active_filament: "Blue PETG",
    })

    Jil::Executor.call(user, set_clear_code, { fil_name: "Blue PETG", fil_color: "#0000FF" })

    cache = user.caches.by(:printer)
    cache.reload
    expect(cache.dig("current", "status")).to eq("printing")
    expect(cache.dig("current", "print_name")).to eq("ActivePrint")
    expect(cache.dig("current", "filament_name")).to eq("Blue PETG")
    expect(cache.dig("current", "filament_color")).to eq("#0000FF")
  end
end
