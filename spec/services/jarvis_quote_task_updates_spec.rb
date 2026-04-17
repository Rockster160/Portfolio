RSpec.describe "Jil tasks with quoted command arguments" do
  def validate!(code)
    Jil::Validator.validate!(code)
  end

  it "validates Task 46 Departed House with quoted ping content" do
    code = <<~'JIL'
      w2b4a = Global.input_data()::Hash
      action = w2b4a.get("action")::Any
      location = w2b4a.get("location")::Any
      wcb3d = Date.from_now(1, "minutes")::Date
      sa853 = Global.trigger("garage", wcb3d, {
        ee595 = Keyval.new("garage", "verify")::Keyval
      })::Schedule
      ec2cf = List.find("TODO")::List
      items = ec2cf.items()::Array
      pba3f = Global.if({
        s927c = items.any?({
          s2ac8 = Keyword.Object()::Hash
          eb78b = s2ac8.presence()::Boolean
        })::Boolean
      }, {
        names = items.map({
          f82c6 = Keyword.Value()::Hash
          df9a5 = f82c6.get("name")::Any
        })::Array
        joinedNames = names.join(", ")::String
        b60fc = Global.command("Ping me \"Not done: #{joinedNames}\"")::String
      }, {})::Any
    JIL
    expect { validate!(code) }.not_to raise_error
  end

  it "validates Task 3 Hourly Server Checker with quoted ping content" do
    code = <<~'JIL'
      c48c2 = Array.new({
        vdd7a = String.new("broker")::String
        d6096 = String.new("pkut")::String
      })::Array
      sabc5 = c48c2.each({
        app = Keyword.Object()::Any
        *last_ping = Global.get_cache("jil", "#{app}_uptime_ping")::Date
        z24eb = Global.if({
          q18fc = Date.ago(45, "minutes")::Date
          *o9fd4 = Boolean.compare(last_ping, "<", q18fc)::Boolean
        }, {
          msg = String.new("#{app} Sidekiq is down!")::String
          cdc75 = List.find("Chores")::List
          s5819 = Global.if({
            g1d94 = cdc75.has_item?(msg)::Boolean
          }, {}, {
            rf4d7 = cdc75.add(msg)::Boolean
            m28fa = Global.command("Ping me \"#{msg}\"")::String
          })::Any
        }, {})::Any
      })::Array
    JIL
    expect { validate!(code) }.not_to raise_error
  end

  it "validates Task 49 Arrived at Workout with quoted ping content" do
    code = <<~'JIL'
      i2cf5 = Hash.new({
        u7ed9 = Keyval.new("Momentum", "Bouldering")::Keyval
        j88e3 = Keyval.new("Lighten", "GolfSim")::Keyval
        jcb12 = Keyval.new("ParkourUtah", "PKUT")::Keyval
        c3be9 = Keyval.new("Lowes", "Lowes")::Keyval
      })::Hash
      pf3f5 = Global.input_data()::Hash
      action = pf3f5.get("action")::String
      location = pf3f5.get("location")::String
      r28f0 = i2cf5.each({
        key = Keyword.Key()::String
        val = Keyword.Value()::String
        tef78 = Global.if({
          rc1bf = Boolean.compare(location, "==", key)::Boolean
        }, {
          *workoutCache = Global.get_cache("workout", "next")::String
          g52ae = Global.if({
            j5f93 = workoutCache.presence()::Boolean
          }, {}, {
            uf1cb = Global.set_cache("workout", "next", val)::Any
          })::Any
          *workout = Boolean.or(workoutCache, location)::String
          f3ca2 = Global.command("Remind me to Start Workout in 2 minutes")::String
          u01a0 = Global.command("ping me \"It looks like it's time to workout at #{workout}\"")::String
          mffce = Date.from_now(2, "minutes")::Date
          p1446 = Global.trigger("workout", "", {
            cd7c0 = Keyval.keyHash("autoadd", {
              scf55 = Keyval.new("name", workout)::Keyval
            })::Keyval
          })::Schedule
        }, {})::Any
      })::Hash
      l7da1 = Global.print("action(#{action}) location(#{location})")::String
    JIL
    expect { validate!(code) }.not_to raise_error
  end
end
