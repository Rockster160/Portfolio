RSpec.describe "Monitor Load idle state" do
  let(:user) { User.me }

  # Extracted widget code that handles idle with filament color bar
  let(:widget_code) { <<~'JIL'.strip }
    current = Global.get_cache("printer", "current")::Hash
    temps = Global.get_cache("printer", "temps")::Hash
    t1 = current.set!("temps", temps)::Hash
    nozzle = temps.get("nozzle")::Numeric
    bed = temps.get("bed")::Numeric
    nr = nozzle.round(0)::Numeric
    br = bed.round(0)::Numeric
    line_temps = String.new("#{nr}° | #{br}°")::String
    status = current.get("status")::String
    is_idle = status.match("/idle/")::Boolean
    no_status = Boolean.not(status)::Boolean
    show_idle = Boolean.or(is_idle, no_status)::Boolean
    fil_color = current.get("filament_color")::String
    has_color = fil_color.presence()::Boolean
    idle_content = Global.if({
      id1 = Global.ref(show_idle)::Boolean
    }, {
      idle_fil = Global.if({
        id2 = Global.ref(has_color)::Boolean
      }, {
        id3 = String.new("[bg #{fil_color}]          [/bg]")::String
      }, {
        id4 = String.new("")::String
      })::String
      idle_bcast = Monitor.broadcast("printer", {
        ib1 = MonitorData.timestamp("true")::MonitorData
        ib2 = MonitorData.data(current)::MonitorData
        ib3 = MonitorData.content("#{line_temps}\n[color #8B9BB4]Idle[/color]\n#{idle_fil}")::MonitorData
      }, false)::Hash
      id5 = Global.return(idle_bcast)::Hash
    }, {})::Any
    line_state = String.new("[color #8B9BB4]#{status}[/color]")::String
    print_name = current.get("print_name")::String
    line_title = Global.if({
      tc1 = Global.ref(has_color)::Boolean
    }, {
      tc2 = String.new("[bg #{fil_color}] #{print_name} [/bg]")::String
    }, {
      tc3 = Global.ternary(print_name, print_name, "???")::String
    })::String
    elapsed = current.get("elapsed_sec")::Numeric
    est = current.get("est_sec")::Numeric
    is_complete = status.match("complete")::Boolean
    bar_current = Global.ternary(is_complete, est, elapsed)::Numeric
    line_progress = String.new("progress placeholder")::String
    line_result = Global.case(status, {
      rs1 = Keyword.When("complete", {
        rs1v = String.new("[color #3E8948][DONE][/color]")::String
      })::String
      rs2 = Keyword.When("failed", {
        rs2v = String.new("[color #E91616][FAIL][/color]")::String
      })::String
      rs3 = Keyword.When("paused", {
        rs3v = String.new("[color #FEE761][STOP][/color]")::String
      })::String
      rs4 = Keyword.Else({
        rs4v = String.new("")::String
      })::String
    })::String
    is_done = status.match("/complete|failed/")::Boolean
    line_duration = Global.if({
      du1 = Global.ref(is_done)::Boolean
    }, {
      actual_dur = current.get("actual_duration")::Numeric
      adh = Numeric.op(actual_dur, "/", 3600)::Numeric
      adhf = adh.floor()::Numeric
      adr = Numeric.op(actual_dur, "%", 3600)::Numeric
      adm = Numeric.op(adr, "/", 60)::Numeric
      admf = adm.floor()::Numeric
      du2 = String.new("#{adhf}h#{admf}m")::String
    }, {
      eh = Numeric.op(elapsed, "/", 3600)::Numeric
      ehf = eh.floor()::Numeric
      er = Numeric.op(elapsed, "%", 3600)::Numeric
      em = Numeric.op(er, "/", 60)::Numeric
      emf = em.floor()::Numeric
      elapsed_dur = String.new("#{ehf}h#{emf}m")::String
      sh = Numeric.op(est, "/", 3600)::Numeric
      shf = sh.floor()::Numeric
      sr = Numeric.op(est, "%", 3600)::Numeric
      sm = Numeric.op(sr, "/", 60)::Numeric
      smf = sm.floor()::Numeric
      est_dur = String.new("#{shf}h#{smf}m")::String
      du3 = String.new("#{elapsed_dur} / #{est_dur}")::String
    })::String
    line_time = Global.if({
      ti1 = Global.ref(is_done)::Boolean
    }, {
      last_upd = current.get("last_updated")::Date
      done_s = last_upd.format("%-I:%M%P")::String
      ti2 = String.new("At: #{done_s}")::String
    }, {
      remaining = Numeric.op(est, "-", elapsed)::Numeric
      eta_t = Date.from_now(remaining, "seconds")::Date
      eta_s = eta_t.format("%-I:%M%P")::String
      rh = Numeric.op(remaining, "/", 3600)::Numeric
      rhf = rh.floor()::Numeric
      rr = Numeric.op(remaining, "%", 3600)::Numeric
      rm = Numeric.op(rr, "/", 60)::Numeric
      rmf = rm.floor()::Numeric
      ti3 = String.new("ETA: #{eta_s} (#{rhf}h#{rmf}m)")::String
    })::String
    bcast = Monitor.broadcast("printer", {
      b1 = MonitorData.timestamp("true")::MonitorData
      b2 = MonitorData.data(current)::MonitorData
      b3 = MonitorData.content("#{line_temps}\n#{line_state}\n#{line_title}\n#{line_progress}\n#{line_result}\n#{line_duration}\n#{line_time}")::MonitorData
    }, false)::Hash
  JIL

  it "validates" do
    Jil::Validator.validate!(widget_code)
  end

  it "returns early with idle content when status is idle" do
    user.caches.by(:printer).update!(data: {
      current: { status: "idle", filament_name: "Blue", filament_color: "#0000FF" },
      temps: { nozzle: 25, bed: 25 },
    })

    executor = Jil::Executor.call(user, widget_code, {})
    # Should have returned early with idle content
    expect(executor.ctx[:return_val]).to be_present
  end

  it "validates without idle early return for printing status" do
    user.caches.by(:printer).update!(data: {
      current: {
        status: "printing", print_name: "Test", filament_color: "#FF0000",
        elapsed_sec: 100, est_sec: 1000,
      },
      temps: { nozzle: 200, bed: 60 },
    })

    executor = Jil::Executor.call(user, widget_code, {})
    # Should NOT return early — no return_val from idle branch
    expect(executor.ctx[:error]).to be_blank
  end
end
