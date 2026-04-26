require "rails_helper"

RSpec.describe "Task 42 (Deploying...) deploy state via cache" do
  let(:user) { User.me }

  let(:code) {
    <<~'JIL'
      *input = Global.input_data()::Hash
      boolFalse = Boolean.new(false)::Boolean
      deployVal = input.get("deploy")::String
      isStart = deployVal.match("start")::Boolean
      isSuccess = deployVal.match("success")::Boolean
      isFailed = deployVal.match("failed")::Boolean
      isFinished = Boolean.or(isSuccess, isFailed)::Boolean

      ifStart = Global.if({
        refStart = Global.ref(isStart)::Boolean
      }, {
        startData = input.splat({
          sha = Keyword.ItemKey("sha")::String
          merge = Keyword.ItemKey("merge")::String
          author = Keyword.ItemKey("author")::String
          message = Keyword.ItemKey("message")::String
        })::Hash
        startTime = Date.now()::Date
        withMeta = startData.setData!({
          setStatus = Keyval.new("status", "deploying")::Keyval
          setStart = Keyval.new("start_time", startTime)::Keyval
        })::Hash
        cacheStart = Global.set_cache("deploy", "current", withMeta)::Any
      }, {})::Any

      ifFinish = Global.if({
        refFinish = Global.ref(isFinished)::Boolean
      }, {
        curr = Global.get_cache("deploy", "current")::Hash
        finishTime = Date.now()::Date
        finalStatus = Global.if({
          refSuccess = Global.ref(isSuccess)::Boolean
        }, {
          okStatus = String.new("success")::String
        }, {
          badStatus = String.new("failed")::String
        })::String
        withFinish = curr.setData!({
          setFinishStatus = Keyval.new("status", finalStatus)::Keyval
          setFinishTime = Keyval.new("finish_time", finishTime)::Keyval
        })::Hash
        cacheFinish = Global.set_cache("deploy", "current", withFinish)::Any

        ifReload = Global.if({
          reloadFlag = Global.get_cache("reload_after_deploy", "")::Boolean
        }, {
          clearReload = Global.set_cache("reload_after_deploy", "", boolFalse)::Any
          reloadCmd = Global.command("reload dashboard")::String
          reloadLog = Global.print("Reloading Dashboard")::String
        }, {})::Any
      }, {})::Any

      current = Global.get_cache("deploy", "current")::Hash
      broadcast = Monitor.broadcast("deploy", {
        payload = MonitorData.data(current)::MonitorData
      }, false)::Monitor
    JIL
  }

  it "validates cleanly" do
    expect { ::Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "validates the visibility-only code used by Tasks 105/106/107" do
    visibility_only = "*input = Global.input_data()::Hash\n"
    expect { ::Jil::Validator.validate!(visibility_only) }.not_to raise_error
  end

  before do
    user.caches.find_by(key: "deploy")&.destroy
    user.caches.find_by(key: "reload_after_deploy")&.destroy
  end

  it "writes deploy data to cache on deploy:start with new sha" do
    received = nil
    allow(::MonitorChannel).to receive(:broadcast_to) { |_user, payload| received = payload }

    Jil::Executor.call(user, code, {
      id: "deploy", deploy: "start",
      sha: "new-sha", merge: "new-merge",
      author: "Rocco", message: "Test deploy",
    })

    cached = user.caches.dig("deploy", "current")
    expect(cached[:sha]).to eq("new-sha")
    expect(cached[:status]).to eq("deploying")
    expect(received[:data][:sha]).to eq("new-sha")
    expect(received[:data][:status]).to eq("deploying")
  end

  it "updates cache to success on deploy:success preserving sha" do
    user.caches.dig_set(
      "deploy", "current",
      { sha: "deploying-sha", status: "deploying", message: "Test" },
    )
    received = nil
    allow(::MonitorChannel).to receive(:broadcast_to) { |_user, payload| received = payload }

    Jil::Executor.call(user, code, { deploy: "success" })

    cached = user.caches.dig("deploy", "current")
    expect(cached[:sha]).to eq("deploying-sha")
    expect(cached[:status]).to eq("success")
    expect(received[:data][:sha]).to eq("deploying-sha")
    expect(received[:data][:status]).to eq("success")
  end

  it "updates cache to failed on deploy:failed preserving sha" do
    user.caches.dig_set(
      "deploy", "current",
      { sha: "deploying-sha", status: "deploying" },
    )
    received = nil
    allow(::MonitorChannel).to receive(:broadcast_to) { |_user, payload| received = payload }

    Jil::Executor.call(user, code, { deploy: "failed" })

    cached = user.caches.dig("deploy", "current")
    expect(cached[:status]).to eq("failed")
    expect(received[:data][:sha]).to eq("deploying-sha")
    expect(received[:data][:status]).to eq("failed")
  end

  it "broadcasts cache state on resync without changing it" do
    user.caches.dig_set(
      "deploy", "current",
      { sha: "stable-sha", status: "success" },
    )
    received = nil
    allow(::MonitorChannel).to receive(:broadcast_to) { |_user, payload| received = payload }

    Jil::Executor.call(user, code, { channel: "deploy", resync: true })

    cached = user.caches.dig("deploy", "current")
    expect(cached[:sha]).to eq("stable-sha")
    expect(cached[:status]).to eq("success")
    expect(received[:data][:sha]).to eq("stable-sha")
  end
end
