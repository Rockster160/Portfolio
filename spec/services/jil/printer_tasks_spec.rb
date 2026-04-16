RSpec.describe "Printer Tasks", type: :request do
  include ActiveJob::TestHelper

  let(:user) { User.me }
  let(:api_key) { user.api_keys.create! }
  let(:auth_headers) { { "Authorization" => "Bearer #{api_key.key}" } }

  before do
    api_key
    user.tasks.destroy_all
    user.action_events.destroy_all
  end

  def trigger_printer(payload)
    post "/jil/trigger/printer", params: payload, headers: auth_headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  def trigger_hass(payload)
    post "/jil/trigger/hass-update", params: payload, headers: auth_headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  def run_jil(code, input_data)
    executor = Jil::Executor.call(user, code, input_data)
    @ctx = executor.ctx
    expect([@ctx[:error_line], @ctx[:error]].compact.join("\n")).to be_blank
    executor
  end

  # -- Function tasks ---------------------------------------------------------
  let(:parse_duration_task) {
    user.tasks.create!(
      name:     "ParseDuration",
      listener: 'function("Duration String" TAB String)::Numeric',
      code:     <<~'JIL'.strip,
        a0 = Global.functionParams({
          str = Keyword.Item()::String
        })::Array
        dur = str.match("/(?:(?<days>\\d+)D)?(?:(?<hours>\\d+)H)?(?:(?<minutes>\\d+)M)?/i")::Hash
        d = dur.get("days")::Numeric
        h = dur.get("hours")::Numeric
        m = dur.get("minutes")::Numeric
        ds = Numeric.op(d, "*", 86400)::Numeric
        hs = Numeric.op(h, "*", 3600)::Numeric
        ms = Numeric.op(m, "*", 60)::Numeric
        dh = Numeric.op(ds, "+", hs)::Numeric
        total = Numeric.op(dh, "+", ms)::Numeric
        ret = Global.return(total)::Numeric
      JIL
    )
  }

  let(:parse_printer_data_task) {
    user.tasks.create!(
      name:     "ParsePrinterData",
      listener: 'function("Printer Data" TAB Hash)::Hash',
      code:     <<~'JIL'.strip,
        a0 = Global.functionParams({
          data = Keyword.Item()::Hash
        })::Array
        topic = data.get("topic")::String
        device = data.get("deviceIdentifier")::String
        job = data.get("job")::Hash
        file = job.get("file")::Hash
        raw_name = file.get("display")::String
        print_name = raw_name.replace("/(-?(\\d+D)?(\\d+H)?(\\d+M)?\\.gcode)$/", "")::String
        dur_str = raw_name.match("/-(\\d+[DHM]+(?:\\d+[DHM]+)*)\\.gcode$/")::String
        cura_est = Custom.ParseDuration(dur_str)::Numeric
        octo_est = job.get("estimatedPrintTime")::Numeric
        has_cura = cura_est.positive?()::Boolean
        est_sec = Global.ternary(has_cura, cura_est, octo_est)::Numeric
        progress = data.get("progress")::Hash
        elapsed = progress.get("printTime")::Numeric
        pct_raw = Numeric.op(elapsed, "/", est_sec)::Numeric
        pct_100 = Numeric.op(pct_raw, "*", 100)::Numeric
        pct = pct_100.round(1)::Numeric
        remaining = progress.get("printTimeLeft")::Numeric
        state = data.get("state")::Hash
        error_msg = state.get("error")::String
        filament = job.get("filament")::Hash
        tool0 = filament.get("tool0")::Hash
        fil_length = tool0.get("length")::Numeric
        fil_volume = tool0.get("volume")::Numeric
        result = Hash.new({
          b2 = Keyval.new("topic", topic)::Keyval
          b3 = Keyval.new("device", device)::Keyval
          b4 = Keyval.new("print_name", print_name)::Keyval
          b5 = Keyval.new("cura_est_sec", cura_est)::Keyval
          b6 = Keyval.new("octo_est_sec", octo_est)::Keyval
          b7 = Keyval.new("est_sec", est_sec)::Keyval
          b8 = Keyval.new("progress", pct)::Keyval
          b9 = Keyval.new("elapsed_sec", elapsed)::Keyval
          ba = Keyval.new("remaining_sec", remaining)::Keyval
          bb = Keyval.new("state", state)::Keyval
          bc = Keyval.new("error", error_msg)::Keyval
          bd = Keyval.new("filament_length", fil_length)::Keyval
          be = Keyval.new("filament_volume", fil_volume)::Keyval
        })::Hash
        bf = Global.return(result)::Hash
      JIL
    )
  }

  # -- Filament function tasks ------------------------------------------------
  let(:adjust_filament_task) {
    user.tasks.create!(
      name:     "AdjustFilament",
      listener: 'function("Filament Name" TAB String BR "MM Delta" TAB Numeric)::Hash',
      code:     <<~'JIL'.strip,
        a0 = Global.functionParams({
          fil_name = Keyword.Item()::String
          mm_delta = Keyword.Item()::Numeric
        })::Array
        filaments = Global.get_cache("printer", "filaments")::Hash
        fil = filaments.get(fil_name)::Hash
        old_mm = fil.get("remaining_mm")::Numeric
        new_mm = Numeric.op(old_mm, "+", mm_delta)::Numeric
        mm_per_g = Global.get_cache("printer", "mm_per_gram")::Numeric
        new_g = Numeric.op(new_mm, "/", mm_per_g)::Numeric
        rounded_g = new_g.round(1)::Numeric
        b1 = fil.set!("remaining_mm", new_mm)::Hash
        b2 = fil.set!("remaining_g", rounded_g)::Hash
        b3 = filaments.set!(fil_name, fil)::Hash
        b4 = Global.set_cache("printer", "filaments", filaments)::Any
        ret = Global.return(fil)::Hash
      JIL
    )
  }

  let(:active_filament_names_task) {
    user.tasks.create!(
      name:     "ActiveFilamentNames",
      listener: 'function()::Array',
      code:     <<~'JIL'.strip,
        a0 = Global.functionParams({})::Array
        filaments = Global.get_cache("printer", "filaments")::Hash
        all_names = filaments.keys()::Array
        active = all_names.select({
          name = Keyword.Object()::String
          fil = filaments.get(name)::Hash
          rem = fil.get("remaining_mm")::Numeric
          b1 = rem.positive?()::Boolean
        })::Array
        ret = Global.return(active)::Array
      JIL
    )
  }

  let(:change_event_filament_task) {
    user.tasks.create!(
      name:     "ChangeEventFilament",
      listener: 'function("Start Event ID" TAB Numeric BR "New Filament" TAB String)::Hash',
      code:     <<~'JIL'.strip,
        a0 = Global.functionParams({
          start_id = Keyword.Item()::Numeric
          new_fil = Keyword.Item()::String
        })::Array
        start_evt = ActionEvent.find(start_id)::ActionEvent
        s_data = start_evt.data()::Hash
        old_fil = s_data.get("filament_name")::String
        fil_length = s_data.get("filament_length")::Numeric
        a1 = s_data.set!("filament_name", new_fil)::Hash
        a2 = ActionEvent.update!(start_evt, {
          a3 = ActionEventData.data(s_data)::ActionEventData
        })::ActionEvent
        fin_search = ActionEvent.search("name::PrintFinish", 50, "DESC")::Array
        fin_evt = fin_search.find({
          fi = Keyword.Object()::ActionEvent
          fi_d = fi.data()::Hash
          fi_sid = fi_d.get("start_event_id")::Numeric
          b1 = Boolean.compare(fi_sid, "==", start_id)::Boolean
        })::ActionEvent
        fail_search = ActionEvent.search("name::PrintFailed", 50, "DESC")::Array
        fail_evt = fail_search.find({
          fa = Keyword.Object()::ActionEvent
          fa_d = fa.data()::Hash
          fa_sid = fa_d.get("start_event_id")::Numeric
          b2 = Boolean.compare(fa_sid, "==", start_id)::Boolean
        })::ActionEvent
        fin_id = fin_evt.id()::Numeric
        fail_id2 = fail_evt.id()::Numeric
        has_fin = fin_id.positive?()::Boolean
        has_fail = fail_id2.positive?()::Boolean
        completed = Boolean.or(has_fin, has_fail)::Boolean
        c0 = Global.if({
          c1 = Global.ref(completed)::Boolean
        }, {
          comp_evt = Global.ternary(has_fin, fin_evt, fail_evt)::ActionEvent
          comp_data = comp_evt.data()::Hash
          comp_len = comp_data.get("filament_length")::Numeric
          neg_len = Numeric.op(comp_len, "*", -1)::Numeric
          c2 = Custom.AdjustFilament(old_fil, comp_len)::Hash
          c3 = Custom.AdjustFilament(new_fil, neg_len)::Hash
          c4 = comp_data.set!("filament_name", new_fil)::Hash
          c5 = ActionEvent.update!(comp_evt, {
            c6 = ActionEventData.data(comp_data)::ActionEventData
          })::ActionEvent
        }, {
          cur = Global.get_cache("printer", "current")::Hash
          d1 = cur.set!("filament_name", new_fil)::Hash
          d2 = Global.set_cache("printer", "current", cur)::Any
        })::Any
        result = Hash.keyval("changed", true)::Hash
        ret = Global.return(result)::Hash
      JIL
    )
  }

  # -- Printer event tasks ----------------------------------------------------
  let(:started_task) {
    user.tasks.create!(
      name:     "Printer - Started",
      listener: 'printer:topic:"Print Started"',
      code:     <<~'JIL'.strip,
        *raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        print_name = pd.get("print_name")::String
        est_sec = pd.get("est_sec")::Numeric
        device = pd.get("device")::String
        cura_est = pd.get("cura_est_sec")::Numeric
        octo_est = pd.get("octo_est_sec")::Numeric
        fil_len = pd.get("filament_length")::Numeric
        act_fil = Global.get_cache("printer", "active_filament")::String
        event = ActionEvent.create({
          a1 = ActionEventData.name("PrintStart")::ActionEventData
          a2 = ActionEventData.notes(print_name)::ActionEventData
          a3 = ActionEventData.data({
            a4 = Keyval.new("device", device)::Keyval
            a5 = Keyval.new("estimated_seconds", est_sec)::Keyval
            a6 = Keyval.new("cura_est_sec", cura_est)::Keyval
            a7 = Keyval.new("octo_est_sec", octo_est)::Keyval
            a8 = Keyval.new("filament_length", fil_len)::Keyval
            af1 = Keyval.new("filament_name", act_fil)::Keyval
          })::ActionEventData
        })::ActionEvent
        evtStart = event.timestamp()::Date
        estFinish = evtStart.add(est_sec, "seconds")::Date
        event_id = event.id()::Numeric
        cache_data = Hash.new({
          a9 = Keyval.new("event_id", event_id)::Keyval
          aa = Keyval.new("print_name", print_name)::Keyval
          ab = Keyval.new("est_sec", est_sec)::Keyval
          ac = Keyval.new("start_time", evtStart)::Keyval
          ad = Keyval.new("est_finish_time", estFinish)::Keyval
          ae = Keyval.new("status", "printing")::Keyval
          af = Keyval.new("progress", "0")::Keyval
          ag = Keyval.new("elapsed_sec", "0")::Keyval
          ah = Keyval.new("remaining_sec", est_sec)::Keyval
          ai = Keyval.new("last_updated", evtStart)::Keyval
          af2 = Keyval.new("filament_name", act_fil)::Keyval
        })::Hash
        aj = Global.set_cache("printer", "current", cache_data)::Any
        ak = Monitor.refresh("printer", "")::Hash
      JIL
    )
  }

  let(:progress_task) {
    user.tasks.create!(
      name:     "Printer - Progress",
      listener: 'printer:topic:"Print Progress"',
      code:     <<~'JIL'.strip,
        raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        print_name = pd.get("print_name")::String
        est_sec = pd.get("est_sec")::Numeric
        rounded_pct = pd.get("progress")::Numeric
        elapsed = pd.get("elapsed_sec")::Numeric
        remaining = pd.get("remaining_sec")::Numeric
        current = Global.get_cache("printer", "current")::Hash
        bb = Global.if({
          bc = current.presence()::Any
        }, {
          now = Date.now()::Date
          bd = current.set!("progress", rounded_pct)::Hash
          be = current.set!("elapsed_sec", elapsed)::Hash
          bf = current.set!("remaining_sec", remaining)::Hash
          bg = current.set!("last_updated", now)::Hash
          b0 = Global.set_cache("printer", "current", current)::Any
        }, {
          device = pd.get("device")::String
          start_time = Date.ago(elapsed, "seconds")::Date
          est_finish = start_time.add(est_sec, "seconds")::Date
          event = ActionEvent.create({
            bh = ActionEventData.name("PrintStart")::ActionEventData
            bi = ActionEventData.notes(print_name)::ActionEventData
            bj = ActionEventData.timestamp(start_time)::ActionEventData
            bk = ActionEventData.data({
              bl = Keyval.new("device", device)::Keyval
              bm = Keyval.new("estimated_seconds", est_sec)::Keyval
              bn = Keyval.new("backfilled", true)::Keyval
            })::ActionEventData
          })::ActionEvent
          new_event_id = event.id()::Numeric
          new_cache = Hash.new({
            bo = Keyval.new("event_id", new_event_id)::Keyval
            bp = Keyval.new("print_name", print_name)::Keyval
            bq = Keyval.new("est_sec", est_sec)::Keyval
            br = Keyval.new("start_time", start_time)::Keyval
            bs = Keyval.new("est_finish_time", est_finish)::Keyval
            bt = Keyval.new("status", "printing")::Keyval
            bu = Keyval.new("progress", rounded_pct)::Keyval
            bv = Keyval.new("elapsed_sec", elapsed)::Keyval
            bw = Keyval.new("remaining_sec", remaining)::Keyval
            bx = Keyval.new("last_updated", start_time)::Keyval
          })::Hash
          b0 = Global.set_cache("printer", "current", new_cache)::Any
        })::Any
        by = Monitor.refresh("printer", "")::Hash
      JIL
    )
  }

  let(:finished_task) {
    user.tasks.create!(
      name:     "Printer - Finished",
      listener: 'printer:topic:"Print Done"',
      code:     <<~'JIL'.strip,
        raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        print_name = pd.get("print_name")::String
        est_sec = pd.get("est_sec")::Numeric
        elapsed = pd.get("elapsed_sec")::Numeric
        fil_len = pd.get("filament_length")::Numeric
        current = Global.get_cache("printer", "current")::Hash
        start_event_id = current.get("event_id")::Numeric
        start_time = current.get("start_time")::Date
        cur_fil = current.get("filament_name")::String
        actual_dur = Date.now()::Date
        actual_duration = Numeric.op(actual_dur, "-", start_time)::Numeric
        event = ActionEvent.create({
          c1 = ActionEventData.name("PrintFinish")::ActionEventData
          c2 = ActionEventData.notes(print_name)::ActionEventData
          c3 = ActionEventData.data({
            c4 = Keyval.new("actual_seconds", elapsed)::Keyval
            c5 = Keyval.new("estimated_seconds", est_sec)::Keyval
            c6 = Keyval.new("start_event_id", start_event_id)::Keyval
            c7 = Keyval.new("actual_duration", actual_duration)::Keyval
            c7b = Keyval.new("filament_length", fil_len)::Keyval
            c7f = Keyval.new("filament_name", cur_fil)::Keyval
          })::ActionEventData
        })::ActionEvent
        finish_id = event.id()::Numeric
        neg_fil = Numeric.op(fil_len, "*", -1)::Numeric
        has_fil = cur_fil.presence()::Boolean
        cf1 = Global.if({
          cf2 = Global.ref(has_fil)::Boolean
        }, {
          cf3 = Custom.AdjustFilament(cur_fil, neg_fil)::Hash
        }, {})::Any
        c8 = current.set!("status", "complete")::Hash
        c9 = current.set!("finish_event_id", finish_id)::Hash
        ca = current.set!("actual_duration", actual_duration)::Hash
        cb = current.set!("progress", 100)::Hash
        cc = current.set!("elapsed_sec", elapsed)::Hash
        cd = current.set!("remaining_sec", 0)::Hash
        ce = current.set!("last_updated", actual_dur)::Hash
        cfl = current.set!("filament_length", fil_len)::Hash
        cf = Global.set_cache("printer", "current", current)::Any
        cg = Monitor.refresh("printer", "")::Hash
      JIL
    )
  }

  let(:failed_task) {
    user.tasks.create!(
      name:     "Printer - Failed",
      listener: "printer:topic:/Print (Failed|Cancelled)/",
      code:     <<~'JIL'.strip,
        *raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        topic = pd.get("topic")::String
        print_name = pd.get("print_name")::String
        elapsed = pd.get("elapsed_sec")::Numeric
        error_msg = pd.get("error")::String
        fil_len = pd.get("filament_length")::Numeric
        current = Global.get_cache("printer", "current")::Hash
        start_event_id = current.get("event_id")::Numeric
        cur_fil = current.get("filament_name")::String
        event = ActionEvent.create({
          d1 = ActionEventData.name("PrintFailed")::ActionEventData
          d2 = ActionEventData.notes(print_name)::ActionEventData
          d3 = ActionEventData.data({
            d4 = Keyval.new("reason", topic)::Keyval
            d5 = Keyval.new("error", error_msg)::Keyval
            d6 = Keyval.new("elapsed_seconds", elapsed)::Keyval
            d7 = Keyval.new("start_event_id", start_event_id)::Keyval
            d7f = Keyval.new("filament_length", fil_len)::Keyval
            d7n = Keyval.new("filament_name", cur_fil)::Keyval
          })::ActionEventData
        })::ActionEvent
        fail_id = event.id()::Numeric
        neg_fil = Numeric.op(fil_len, "*", -1)::Numeric
        has_fil = cur_fil.presence()::Boolean
        df1 = Global.if({
          df2 = Global.ref(has_fil)::Boolean
        }, {
          df3 = Custom.AdjustFilament(cur_fil, neg_fil)::Hash
        }, {})::Any
        d8 = current.set!("status", "failed")::Hash
        d9 = current.set!("fail_event_id", fail_id)::Hash
        da = current.set!("error", error_msg)::Hash
        db = current.set!("elapsed_sec", elapsed)::Hash
        now = Date.now()::Date
        dc = current.set!("last_updated", now)::Hash
        dd = Global.set_cache("printer", "current", current)::Any
        de = Monitor.refresh("printer", "")::Hash
      JIL
    )
  }

  # -- HASS temp task ---------------------------------------------------------
  let(:hass_temp_task) {
    user.tasks.create!(
      name:     "Printer - HASS Temps",
      listener: 'hass-update:source:octoprint',
      code:     <<~'JIL'.strip,
        data = Global.input_data()::Hash
        bed = data.get("bed")::Numeric
        bed_target = data.get("bed_target")::Numeric
        nozzle = data.get("nozzle")::Numeric
        nozzle_target = data.get("nozzle_target")::Numeric
        now = Date.now()::Date
        temps = Hash.new({
          e1 = Keyval.new("bed", bed)::Keyval
          e2 = Keyval.new("bed_target", bed_target)::Keyval
          e3 = Keyval.new("nozzle", nozzle)::Keyval
          e4 = Keyval.new("nozzle_target", nozzle_target)::Keyval
          e5 = Keyval.new("updated_at", now)::Keyval
        })::Hash
        e6 = Global.set_cache("printer", "temps", temps)::Any
      JIL
    )
  }

  # -- Monitor load task -------------------------------------------------------
  let(:monitor_load_task) {
    user.tasks.create!(
      name:     "Printer - Monitor Load",
      listener: "monitor:channel:printer",
      code:     <<~'JIL'.strip,
        current = Global.get_cache("printer", "current")::Hash
        temps = Global.get_cache("printer", "temps")::Hash
        f1 = current.set!("temps", temps)::Hash
        f2 = Monitor.broadcast("printer", {
          f3 = MonitorData.timestamp(true)::MonitorData
          f4 = MonitorData.data(current)::MonitorData
        }, false)::Hash
      JIL
    )
  }

  # Ensure function + monitor tasks exist for all tests
  before do
    parse_duration_task
    parse_printer_data_task
    monitor_load_task
  end

  # -- Webhook payloads -------------------------------------------------------
  let(:job_data) {
    {
      file:               { name: "Slime-24M.gcode", display: "Slime-24M.gcode" },
      estimatedPrintTime: 1440,
      filament:           { tool0: { length: 954.19, volume: 2.3 } },
    }
  }

  let(:started_payload) {
    {
      deviceIdentifier: "zoro-pi-1",
      topic:            "Print Started",
      job:              job_data,
      progress:         { completion: 0, printTime: 0, printTimeLeft: 1440 },
    }
  }

  let(:progress_payload) {
    {
      deviceIdentifier: "zoro-pi-1",
      topic:            "Print Progress",
      job:              job_data,
      progress:         { completion: 50.5, printTime: 720, printTimeLeft: 710 },
      currentZ:         10.5,
    }
  }

  let(:finished_payload) {
    {
      topic:    "Print Done",
      job:      job_data,
      progress: { completion: 100, printTime: 1380, printTimeLeft: 0 },
    }
  }

  let(:failed_payload) {
    {
      topic:    "Print Failed",
      job:      job_data,
      progress: { completion: 30.0, printTime: 400, printTimeLeft: 0 },
      state:    { text: "Error", error: "Thermal runaway", flags: { error: true } },
    }
  }

  let(:hass_temp_payload) {
    {
      source:        "octoprint",
      changed:       "nozzle",
      bed:           45.2,
      bed_target:    60,
      nozzle:        198.5,
      nozzle_target: 200,
      pressed_at:    Time.current.iso8601,
    }
  }

  # -- Function task unit tests -----------------------------------------------
  describe "ParseDuration function" do
    it "parses minutes" do
      run_jil('result = Custom.ParseDuration("24M")::Numeric', {})
      expect(@ctx.dig(:vars, :result, :value)).to eq(1440)
    end

    it "parses hours and minutes" do
      run_jil('result = Custom.ParseDuration("4H55M")::Numeric', {})
      expect(@ctx.dig(:vars, :result, :value)).to eq((4 * 3600) + (55 * 60))
    end

    it "parses days, hours, minutes" do
      run_jil('result = Custom.ParseDuration("1D2H30M")::Numeric', {})
      expect(@ctx.dig(:vars, :result, :value)).to eq(86_400 + 7200 + 1800)
    end

    it "returns 0 for empty string" do
      run_jil('result = Custom.ParseDuration("")::Numeric', {})
      expect(@ctx.dig(:vars, :result, :value)).to eq(0)
    end
  end

  describe "ParsePrinterData function" do
    it "extracts and formats all fields" do
      input = started_payload.merge(state: { text: "Printing", error: "" })
      code = <<~JIL.strip
        raw = Global.input_data()::Hash
        result = Custom.ParsePrinterData(raw)::Hash
      JIL
      run_jil(code, input)
      result = @ctx.dig(:vars, :result, :value)
      expect(result).to include(
        "print_name"      => "Slime",
        "topic"           => "Print Started",
        "device"          => "zoro-pi-1",
        "cura_est_sec"    => 1440,
        "octo_est_sec"    => 1440,
        "est_sec"         => 1440,
        "progress"        => 0.0,
        "elapsed_sec"     => 0,
        "remaining_sec"   => 1440,
        "filament_length" => 954.19,
        "filament_volume" => 2.3,
      )
    end

    it "prefers Cura estimate over OctoPrint" do
      payload = started_payload.deep_dup
      payload[:job][:file][:display] = "BigPrint-4H55M.gcode"
      payload[:job][:estimatedPrintTime] = 9999
      code = <<~JIL.strip
        raw = Global.input_data()::Hash
        result = Custom.ParsePrinterData(raw)::Hash
      JIL
      run_jil(code, payload)
      result = @ctx.dig(:vars, :result, :value)
      expect(result["est_sec"]).to eq((4 * 3600) + (55 * 60))
    end

    it "falls back to OctoPrint when no Cura time" do
      payload = started_payload.deep_dup
      payload[:job][:file][:display] = "NoDuration.gcode"
      payload[:job][:estimatedPrintTime] = 999
      code = <<~JIL.strip
        raw = Global.input_data()::Hash
        result = Custom.ParsePrinterData(raw)::Hash
      JIL
      run_jil(code, payload)
      result = @ctx.dig(:vars, :result, :value)
      expect(result["est_sec"]).to eq(999)
    end
  end

  # -- HASS temp tests --------------------------------------------------------
  describe "HASS temp webhook" do
    before { hass_temp_task }

    it "stores temps in printer:temps cache" do
      trigger_hass(hass_temp_payload)

      user.caches.by(:printer).reload
      temps = user.caches.by(:printer).data
      temp_data = (temps["temps"] || temps[:temps])
      expect(temp_data).to be_present
      temp_data = temp_data.with_indifferent_access
      expect(temp_data["nozzle"]).to eq(198.5)
      expect(temp_data["nozzle_target"]).to eq(200)
      expect(temp_data["bed"]).to eq(45.2)
      expect(temp_data["bed_target"]).to eq(60)
      expect(temp_data["updated_at"]).to be_present
    end

    it "does not affect current print cache" do
      user.caches.by(:printer).update!(data: {
        "current" => { "print_name" => "Slime", "status" => "printing" },
      })

      trigger_hass(hass_temp_payload)

      user.caches.by(:printer).reload
      data = user.caches.by(:printer).data
      current = (data["current"] || data[:current])
      expect(current).to be_present
      expect(current.with_indifferent_access["print_name"]).to eq("Slime")
    end
  end

  # -- Monitor load tests ------------------------------------------------------
  describe "Monitor Load" do
    before { monitor_load_task }

    it "broadcasts cached print state on resync" do
      user.caches.by(:printer).update!(data: {
        "current" => {
          "status" => "complete", "print_name" => "Slime",
          "est_sec" => 1440, "event_id" => 1,
        },
      })

      # Simulate what resync does — triggers monitor:channel:printer
      run_jil(monitor_load_task.code, { channel: "printer", resync: true })

      # The task executed without error (broadcast happened)
      expect(@ctx[:error]).to be_blank
    end

    it "broadcasts empty state when no cache exists" do
      run_jil(monitor_load_task.code, { channel: "printer", resync: true })
      expect(@ctx[:error]).to be_blank
    end
  end

  # -- Webhook integration tests ----------------------------------------------
  describe "webhook authentication" do
    before { started_task }

    it "returns 200 with valid API key" do
      trigger_printer(started_payload)
    end

    it "returns 204 without authentication" do
      post "/jil/trigger/printer", params: started_payload, as: :json
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "Print Started webhook" do
    before { started_task }

    it "creates a PrintStart event and sets cache with timestamps" do
      trigger_printer(started_payload)

      event = user.action_events.order(:id).last
      expect(event.name).to eq("PrintStart")
      expect(event.notes).to eq("Slime")

      user.caches.by(:printer).reload
      cache = user.caches.by(:printer).data
      current = (cache["current"] || cache[:current]).with_indifferent_access
      expect(current).to include("event_id" => event.id, "status" => "printing")
      expect(current["start_time"]).to be_present
      expect(current["est_finish_time"]).to be_present
      expect(current["last_updated"]).to be_present
    end
  end

  describe "Print Progress webhook" do
    before { progress_task }

    context "with existing cache" do
      before do
        user.caches.by(:printer).update!(data: {
          "current" => {
            "print_name" => "Slime", "est_sec" => 1440, "event_id" => 1,
            "status" => "printing",
            "start_time" => 10.minutes.ago.iso8601,
            "est_finish_time" => 14.minutes.from_now.iso8601,
          },
        })
      end

      it "does not create events" do
        event_count = user.action_events.count
        trigger_printer(progress_payload)
        expect(user.action_events.count).to eq(event_count)
      end
    end

    context "without cache (missed start)" do
      it "backfills a PrintStart event" do
        trigger_printer(progress_payload)

        event = user.action_events.order(:id).last
        expect(event.name).to eq("PrintStart")
        expect(event.data).to include("backfilled" => true)
        expect(event.timestamp).to be_within(5.seconds).of(720.seconds.ago)

        user.caches.by(:printer).reload
        cache = user.caches.by(:printer).data
        current = (cache["current"] || cache[:current]).with_indifferent_access
        expect(current["event_id"]).to eq(event.id)
        expect(current["status"]).to eq("printing")
      end
    end
  end

  describe "Print Done webhook" do
    before { finished_task; adjust_filament_task }

    it "creates PrintFinish event and updates cache status to complete" do
      start_time = 20.minutes.ago
      start_event = user.action_events.create!(name: "PrintStart", notes: "Slime", timestamp: start_time)
      user.caches.by(:printer).update!(data: { "current" => {
        "event_id" => start_event.id, "print_name" => "Slime", "est_sec" => 1440,
        "status" => "printing",
        "start_time" => start_time.iso8601,
        "est_finish_time" => (start_time + 1440.seconds).iso8601,
      } })

      trigger_printer(finished_payload)

      event = user.action_events.order(:id).last
      expect(event.name).to eq("PrintFinish")
      expect(event.data["actual_duration"]).to be_within(5).of(20 * 60)
      expect(event.data["filament_length"]).to eq(954.19)

      user.caches.by(:printer).reload
      cache = user.caches.by(:printer).data
      current = (cache["current"] || cache[:current]).with_indifferent_access
      expect(current["status"]).to eq("complete")
      expect(current["finish_event_id"]).to eq(event.id)
      expect(current["actual_duration"]).to be_present
      expect(current["filament_length"]).to eq(954.19)
    end

    it "subtracts filament and stores filament_name on event" do
      start_time = 20.minutes.ago
      start_event = user.action_events.create!(name: "PrintStart", notes: "Slime", timestamp: start_time)
      user.caches.by(:printer).update!(data: {
        current: {
          event_id: start_event.id, print_name: "Slime", est_sec: 1440,
          status: "printing", filament_name: "Red PLA",
          start_time: start_time.iso8601,
          est_finish_time: (start_time + 1440.seconds).iso8601,
        },
        filaments: {
          "Red PLA": { color: "#FF0000", remaining_mm: 330_000, remaining_g: 985.1 },
        },
        mm_per_gram: 335,
      })

      trigger_printer(finished_payload)

      event = user.action_events.order(:id).last
      expect(event.data["filament_name"]).to eq("Red PLA")
      expect(event.data["filament_length"]).to eq(954.19)

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("filaments", "Red PLA", "remaining_mm")).to be_within(0.1).of(330_000 - 954.19)
    end
  end

  describe "Print Failed webhook" do
    before { failed_task; adjust_filament_task }

    it "creates PrintFailed event and updates cache status to failed" do
      start_event = user.action_events.create!(name: "PrintStart", notes: "Slime")
      user.caches.by(:printer).update!(data: { "current" => {
        "event_id" => start_event.id, "print_name" => "Slime", "est_sec" => 1440,
        "status" => "printing",
        "start_time" => 5.minutes.ago.iso8601,
        "est_finish_time" => 19.minutes.from_now.iso8601,
      } })

      trigger_printer(failed_payload)

      event = user.action_events.order(:id).last
      expect(event.name).to eq("PrintFailed")

      user.caches.by(:printer).reload
      cache = user.caches.by(:printer).data
      current = (cache["current"] || cache[:current]).with_indifferent_access
      expect(current["status"]).to eq("failed")
      expect(current["error"]).to eq("Thermal runaway")
      expect(current["fail_event_id"]).to eq(event.id)
    end

    it "subtracts filament and stores filament_name and filament_length on event" do
      start_event = user.action_events.create!(name: "PrintStart", notes: "Slime")
      user.caches.by(:printer).update!(data: {
        current: {
          event_id: start_event.id, print_name: "Slime", est_sec: 1440,
          status: "printing", filament_name: "Blue PETG",
          start_time: 5.minutes.ago.iso8601,
          est_finish_time: 19.minutes.from_now.iso8601,
        },
        filaments: {
          "Blue PETG": { color: "#0000FF", remaining_mm: 200_000, remaining_g: 597.0 },
        },
        mm_per_gram: 335,
      })

      trigger_printer(failed_payload)

      event = user.action_events.order(:id).last
      expect(event.data["filament_name"]).to eq("Blue PETG")
      expect(event.data["filament_length"]).to eq(954.19)

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("filaments", "Blue PETG", "remaining_mm")).to be_within(0.1).of(200_000 - 954.19)
    end
  end

  # -- Filament function tests -------------------------------------------------
  describe "AdjustFilament function" do
    before { adjust_filament_task }

    it "adjusts remaining_mm and syncs remaining_g" do
      user.caches.by(:printer).update!(data: {
        filaments: { "Red PLA": { color: "#FF0000", remaining_mm: 335_000, remaining_g: 1000.0 } },
        mm_per_gram: 335,
      })

      run_jil('result = Custom.AdjustFilament("Red PLA", -1000)::Hash', {})

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("filaments", "Red PLA", "remaining_mm")).to eq(334_000)
      expect(cache.dig("filaments", "Red PLA", "remaining_g")).to be_within(0.1).of(334_000.0 / 335)
    end
  end

  describe "ActiveFilamentNames function" do
    before { active_filament_names_task }

    it "returns only filaments with remaining > 0" do
      user.caches.by(:printer).update!(data: {
        filaments: {
          "Red PLA": { remaining_mm: 100_000 },
          Empty: { remaining_mm: 0 },
          "Blue PETG": { remaining_mm: 50_000 },
        },
      })

      run_jil('result = Custom.ActiveFilamentNames()::Array', {})
      names = @ctx.dig(:vars, :result, :value)
      expect(names).to contain_exactly("Red PLA", "Blue PETG")
    end
  end

  describe "ChangeEventFilament function" do
    before { change_event_filament_task; adjust_filament_task }

    it "for completed print: adjusts both filaments and updates events" do
      user.caches.by(:printer).update!(data: {
        filaments: {
          "Red PLA": { color: "#FF0000", remaining_mm: 300_000, remaining_g: 895.5 },
          "Blue PETG": { color: "#0000FF", remaining_mm: 200_000, remaining_g: 597.0 },
        },
        mm_per_gram: 335,
      })

      start_evt = user.action_events.create!(
        name: "PrintStart", notes: "Slime",
        data: { filament_name: "Red PLA", filament_length: 1000 },
      )
      finish_evt = user.action_events.create!(
        name: "PrintFinish", notes: "Slime",
        data: { start_event_id: start_evt.id, filament_name: "Red PLA", filament_length: 1000 },
      )

      code = "result = Custom.ChangeEventFilament(#{start_evt.id}, \"Blue PETG\")::Hash"
      run_jil(code, {})

      start_evt.reload
      expect(start_evt.data["filament_name"]).to eq("Blue PETG")

      cache = user.caches.by(:printer)
      cache.reload
      # Check filament adjustments first
      expect(cache.dig("filaments", "Red PLA", "remaining_mm")).to eq(301_000), "Red PLA should have gained 1000mm back. Got: #{cache.dig("filaments", "Red PLA", "remaining_mm")}"
      expect(cache.dig("filaments", "Blue PETG", "remaining_mm")).to eq(199_000), "Blue PETG should have lost 1000mm. Got: #{cache.dig("filaments", "Blue PETG", "remaining_mm")}"

      finish_evt.reload
      expect(finish_evt.data["filament_name"]).to eq("Blue PETG")
    end

    it "for ongoing print: updates cache but does not adjust filament amounts" do
      start_evt = user.action_events.create!(
        name: "PrintStart", notes: "Slime",
        data: { filament_name: "Red PLA", filament_length: 1000 },
      )
      user.caches.by(:printer).update!(data: {
        current: { status: "printing", filament_name: "Red PLA", event_id: start_evt.id },
        filaments: {
          "Red PLA": { remaining_mm: 300_000, remaining_g: 895.5 },
          "Blue PETG": { remaining_mm: 200_000, remaining_g: 597.0 },
        },
        mm_per_gram: 335,
      })

      code = "result = Custom.ChangeEventFilament(#{start_evt.id}, \"Blue PETG\")::Hash"
      run_jil(code, {})

      start_evt.reload
      expect(start_evt.data["filament_name"]).to eq("Blue PETG")

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("filaments", "Red PLA", "remaining_mm")).to eq(300_000)
      expect(cache.dig("filaments", "Blue PETG", "remaining_mm")).to eq(200_000)
      expect(cache.dig("current", "filament_name")).to eq("Blue PETG")
    end
  end

  describe "Print Started with filament tracking" do
    before { started_task }

    it "stores active filament on event and cache" do
      user.caches.by(:printer).update!(data: { active_filament: "Red PLA" })

      trigger_printer(started_payload)

      event = user.action_events.order(:id).last
      expect(event.data["filament_name"]).to eq("Red PLA")

      cache = user.caches.by(:printer)
      cache.reload
      expect(cache.dig("current", "filament_name")).to eq("Red PLA")
    end
  end

  describe "full lifecycle: start → progress → finish" do
    before do
      started_task
      progress_task
      finished_task
    end

    it "creates correct events, cache persists with complete status" do
      trigger_printer(started_payload)
      start_event = user.action_events.order(:id).last
      expect(start_event.name).to eq("PrintStart")

      event_count = user.action_events.count
      trigger_printer(progress_payload)
      expect(user.action_events.count).to eq(event_count)

      trigger_printer(finished_payload)
      finish_event = user.action_events.order(:id).last
      expect(finish_event.name).to eq("PrintFinish")
      expect(finish_event.data["start_event_id"]).to eq(start_event.id)

      user.caches.by(:printer).reload
      cache = user.caches.by(:printer).data
      current = (cache["current"] || cache[:current]).with_indifferent_access
      expect(current["status"]).to eq("complete")
      expect(current["print_name"]).to eq("Slime")
    end
  end

  describe "full lifecycle: missed start → progress → finish" do
    before do
      progress_task
      finished_task
    end

    it "backfills start then finishes normally" do
      trigger_printer(progress_payload)
      start_event = user.action_events.order(:id).last
      expect(start_event.data["backfilled"]).to be(true)

      trigger_printer(finished_payload)
      finish_event = user.action_events.order(:id).last
      expect(finish_event.name).to eq("PrintFinish")
      expect(finish_event.data["start_event_id"]).to eq(start_event.id)

      user.caches.by(:printer).reload
      cache = user.caches.by(:printer).data
      current = (cache["current"] || cache[:current]).with_indifferent_access
      expect(current["status"]).to eq("complete")
    end
  end
end
