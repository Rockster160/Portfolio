require "rails_helper"

RSpec.describe "Deploy task code validation (Tasks 42, 105, 106, 107)" do
  let(:task_42_code) {
    <<~'JIL'
      current = Global.get_cache("deploy", "current")::Hash
      broadcast = Monitor.broadcast("deploy", {
        payload = MonitorData.data(current)::MonitorData
      }, false)::Monitor
    JIL
  }

  let(:task_105_code) {
    <<~'JIL'
      *input = Global.input_data()::Hash
      git = input.splat({
        merge = Keyword.ItemKey("merge")::String
        sha = Keyword.ItemKey("sha")::String
        author = Keyword.ItemKey("author")::String
        message = Keyword.ItemKey("message")::String
      })::Hash
      now = Date.now()::Date
      deployData = git.setData!({
        setStatus = Keyval.new("status", "deploying")::Keyval
        setStart = Keyval.new("start_time", now)::Keyval
      })::Hash
      event = ActionEvent.create({
        evtName = ActionEventData.name("Deploy")::ActionEventData
        evtNotes = ActionEventData.notes("Deploying...")::ActionEventData
        evtData = ActionEventData.data({
          refData = Global.ref(deployData)::Hash
        })::ActionEventData
      })::ActionEvent
      eventId = event.id()::Numeric
      withEventId = deployData.set!("event_id", eventId)::Hash
      cacheStart = Global.set_cache("deploy", "current", withEventId)::Any
    JIL
  }

  let(:task_106_code) {
    <<~'JIL'
      *input = Global.input_data()::Hash
      boolFalse = Boolean.new(false)::Boolean
      now = Date.now()::Date
      curr = Global.get_cache("deploy", "current")::Hash
      eventId = curr.get("event_id")::Numeric
      event = ActionEvent.find(eventId)::ActionEvent
      evtData = event.data()::Hash
      startTime = evtData.get("start_time")::Date
      spaceDur = Custom.Duration(startTime, now, 5)::String
      duration = spaceDur.replace(" ", "")::String
      finalData = curr.setData!({
        setStatus = Keyval.new("status", "success")::Keyval
        setFinish = Keyval.new("finish_time", now)::Keyval
        setDuration = Keyval.new("duration", duration)::Keyval
      })::Hash
      updated = event.update!({
        upNotes = ActionEventData.notes("Success")::ActionEventData
        upData = ActionEventData.data({
          refFinal = Global.ref(finalData)::Hash
        })::ActionEventData
      })::ActionEvent
      cacheFinish = Global.set_cache("deploy", "current", finalData)::Any
      ifReload = Global.if({
        reloadFlag = Global.get_cache("reload_after_deploy", "")::Boolean
      }, {
        clearReload = Global.set_cache("reload_after_deploy", "", boolFalse)::Any
        reloadCmd = Global.command("reload dashboard")::String
        reloadLog = Global.print("Reloading Dashboard")::String
      }, {})::Any
    JIL
  }

  let(:task_107_code) {
    <<~'JIL'
      *input = Global.input_data()::Hash
      now = Date.now()::Date
      curr = Global.get_cache("deploy", "current")::Hash
      eventId = curr.get("event_id")::Numeric
      event = ActionEvent.find(eventId)::ActionEvent
      evtData = event.data()::Hash
      startTime = evtData.get("start_time")::Date
      spaceDur = Custom.Duration(startTime, now, 5)::String
      duration = spaceDur.replace(" ", "")::String
      finalData = curr.setData!({
        setStatus = Keyval.new("status", "failed")::Keyval
        setFinish = Keyval.new("finish_time", now)::Keyval
        setDuration = Keyval.new("duration", duration)::Keyval
      })::Hash
      updated = event.update!({
        upNotes = ActionEventData.notes("Failure")::ActionEventData
        upData = ActionEventData.data({
          refFinal = Global.ref(finalData)::Hash
        })::ActionEventData
      })::ActionEvent
      cacheFinish = Global.set_cache("deploy", "current", finalData)::Any
    JIL
  }

  it "validates Task 42 (broadcast-only)" do
    expect { ::Jil::Validator.validate!(task_42_code) }.not_to raise_error
  end

  it "validates Task 105 (deploy start)" do
    expect { ::Jil::Validator.validate!(task_105_code) }.not_to raise_error
  end

  it "validates Task 106 (deploy success)" do
    expect { ::Jil::Validator.validate!(task_106_code) }.not_to raise_error
  end

  it "validates Task 107 (deploy failed)" do
    expect { ::Jil::Validator.validate!(task_107_code) }.not_to raise_error
  end
end
