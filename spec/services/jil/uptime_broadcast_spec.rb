RSpec.describe "Task 335 — Uptime Listener (monitor::uptime)" do
  let(:user) { User.me }

  let(:code) {
    <<~'JIL'
      *input = Global.input_data()::Hash
      newData = input.get("report")::Hash
      oldData = Global.get_cache("servers", "")::Hash
      allData = oldData.merge(newData)::Hash
      *save = Global.set_cache("servers", "", allData)::Hash
      b001a = Monitor.broadcast("uptime", {
        *monitorData = MonitorData.data(allData)::MonitorData
      }, false)::Hash
    JIL
  }

  before do
    user.caches.where(key: "servers").destroy_all
  end

  def captured_broadcasts
    [].tap { |broadcasts|
      allow(MonitorChannel).to receive(:broadcast_to) { |_user, data| broadcasts << data }
    }
  end

  it "merges report data into the servers cache and broadcasts the merged cache" do
    user.caches.create!(key: "servers", data: {
      "Broker" => { "cpu" => 1, "timestamp" => 100 },
    })
    broadcasts = captured_broadcasts

    Jil::Executor.call(user, code, {
      channel: "uptime",
      report:  {
        Portfolio: {
          memory_used_mb:  2200,
          memory_total_mb: 3951,
          cpu:             20,
          load:            0.14,
          disk:            27,
          latency:         0,
          timestamp:       200,
        },
      },
    })

    cache = user.caches.find_by(key: "servers").data.deep_symbolize_keys
    expect(cache.keys).to contain_exactly(:Broker, :Portfolio)
    expect(cache.dig(:Portfolio, :cpu)).to eq(20)
    expect(cache.dig(:Broker, :cpu)).to eq(1)

    expect(broadcasts.size).to eq(1)
    expect(broadcasts.first[:channel]).to eq("uptime")
    expect(broadcasts.first[:data]).to eq(cache)
  end

  it "broadcasts existing cache when fired with refresh-only (no report data)" do
    payload = {
      "Broker"    => {
        "memory_used_mb"  => 1276,
        "memory_total_mb" => 3912,
        "cpu"             => 0,
        "load"            => 0.01,
        "disk"            => 54,
        "latency"         => 0,
        "timestamp"       => 1_778_092_923,
      },
      "Portfolio" => {
        "memory_used_mb"  => 2200,
        "memory_total_mb" => 3951,
        "cpu"             => 20,
        "load"            => 0.14,
        "disk"            => 27,
        "latency"         => 0,
        "timestamp"       => 1_778_092_922,
      },
    }
    user.caches.create!(key: "servers", data: payload)
    broadcasts = captured_broadcasts

    Jil::Executor.call(user, code, { channel: "uptime", refresh: true })

    expect(user.caches.find_by(key: "servers").data.deep_symbolize_keys)
      .to eq(payload.deep_symbolize_keys)
    expect(broadcasts.size).to eq(1)
    expect(broadcasts.first[:data]).to eq(payload.deep_symbolize_keys)
  end
end
