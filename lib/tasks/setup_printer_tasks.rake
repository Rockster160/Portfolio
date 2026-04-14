namespace :printer do
  desc "Create or update Jil tasks for OctoPrint webhook integration"
  task setup: :environment do
    user = User.me
    folder = user.task_folders.find_or_create_by!(name: "Printer")

    find_or_create = ->(name:, listener:, code:) {
      task = user.tasks.find_or_initialize_by(name: name)
      task.assign_attributes(listener: listener, task_folder_id: folder.id, code: code, enabled: true)
      task.save!
      task
    }

    find_or_create.call(
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

    find_or_create.call(
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

    find_or_create.call(
      name:     "Printer - Monitor Load",
      listener: "monitor:channel:printer",
      code:     <<~'JIL'.strip,
        current = Global.get_cache("printer", "current")::Hash
        f1 = Monitor.broadcast("printer", {
          f2 = MonitorData.timestamp(true)::MonitorData
          f3 = MonitorData.data(current)::MonitorData
        }, false)::Hash
      JIL
    )

    find_or_create.call(
      name:     "Printer - Started",
      listener: 'printer:topic:"Print Started"',
      code:     <<~'JIL'.strip,
        raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        print_name = pd.get("print_name")::String
        est_sec = pd.get("est_sec")::Numeric
        device = pd.get("device")::String
        cura_est = pd.get("cura_est_sec")::Numeric
        octo_est = pd.get("octo_est_sec")::Numeric
        fil_len = pd.get("filament_length")::Numeric
        event = ActionEvent.create({
          a1 = ActionEventData.name("PrintStart")::ActionEventData
          a2 = ActionEventData.notes(print_name)::ActionEventData
          a3 = ActionEventData.data({
            a4 = Keyval.new("device", device)::Keyval
            a5 = Keyval.new("estimated_seconds", est_sec)::Keyval
            a6 = Keyval.new("cura_est_sec", cura_est)::Keyval
            a7 = Keyval.new("octo_est_sec", octo_est)::Keyval
            a8 = Keyval.new("filament_length", fil_len)::Keyval
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
          af = Keyval.new("progress", 0)::Keyval
          ag = Keyval.new("elapsed_sec", 0)::Keyval
          ah = Keyval.new("remaining_sec", est_sec)::Keyval
          ai = Keyval.new("last_updated", evtStart)::Keyval
        })::Hash
        aj = Global.set_cache("printer", "current", cache_data)::Any
        ak = Monitor.refresh("printer", "")::Hash
      JIL
    )

    find_or_create.call(
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

    find_or_create.call(
      name:     "Printer - Finished",
      listener: 'printer:topic:"Print Done"',
      code:     <<~'JIL'.strip,
        raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        print_name = pd.get("print_name")::String
        est_sec = pd.get("est_sec")::Numeric
        elapsed = pd.get("elapsed_sec")::Numeric
        current = Global.get_cache("printer", "current")::Hash
        start_event_id = current.get("event_id")::Numeric
        start_time = current.get("start_time")::Date
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
          })::ActionEventData
        })::ActionEvent
        finish_id = event.id()::Numeric
        c8 = current.set!("status", "complete")::Hash
        c9 = current.set!("finish_event_id", finish_id)::Hash
        ca = current.set!("actual_duration", actual_duration)::Hash
        cb = current.set!("progress", 100)::Hash
        cc = current.set!("elapsed_sec", elapsed)::Hash
        cd = current.set!("remaining_sec", 0)::Hash
        ce = current.set!("last_updated", actual_dur)::Hash
        cf = Global.set_cache("printer", "current", current)::Any
        cg = Monitor.refresh("printer", "")::Hash
      JIL
    )

    find_or_create.call(
      name:     "Printer - Failed",
      listener: 'printer:topic:/Print (Failed|Cancelled)/',
      code:     <<~'JIL'.strip,
        raw = Global.input_data()::Hash
        pd = Custom.ParsePrinterData(raw)::Hash
        topic = pd.get("topic")::String
        print_name = pd.get("print_name")::String
        elapsed = pd.get("elapsed_sec")::Numeric
        error_msg = pd.get("error")::String
        current = Global.get_cache("printer", "current")::Hash
        start_event_id = current.get("event_id")::Numeric
        event = ActionEvent.create({
          d1 = ActionEventData.name("PrintFailed")::ActionEventData
          d2 = ActionEventData.notes(print_name)::ActionEventData
          d3 = ActionEventData.data({
            d4 = Keyval.new("reason", topic)::Keyval
            d5 = Keyval.new("error", error_msg)::Keyval
            d6 = Keyval.new("elapsed_seconds", elapsed)::Keyval
            d7 = Keyval.new("start_event_id", start_event_id)::Keyval
          })::ActionEventData
        })::ActionEvent
        fail_id = event.id()::Numeric
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

    find_or_create.call(
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

    Task.recompute_tree_order(user)

    puts "\nCreated/updated printer tasks in '#{folder.name}' folder:"
    user.tasks.where(task_folder_id: folder.id).order(:sort_order).each do |t|
      puts "  #{t.name} — #{t.listener}"
    end
    puts "\nWebhook URL: /jil/trigger/printer (with API key auth)"
    puts "HASS URL: /jil/trigger/hass-update (with API key auth)"
  end
end
