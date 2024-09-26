RSpec.describe Jil::Methods::Monitor do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) {
    <<-JIL
      d27ea = Monitor.loading("hello", true)::Monitor
      ge7eb = Monitor.broadcast("hello", {
        b4424 = MonitorData.content(" 46m  47m  46m  3h\n\n[ico mdi-garage font-size: 100px; color: green;]\n\n\n")::MonitorData
        ie22c = MonitorData.timestamp("")::MonitorData
        id94e = MonitorData.blip(null)::MonitorData
        id94e = MonitorData.data()::MonitorData
      }, false)::Monitor
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  # [Monitor]
  #   #loading(String:UUID)
  #   #broadcast(String:UUID content(MonitorData))
  # *[MonitorData]
  #   #content(Text)
  #   #timestamp(Date|Boolean)
  #   #blip(Numeric?)
  #   #data(Hash)

  context "#broadcast" do
    it "broadcasts the relevant data to the channel" do
      expect_successful_jil

      expect(ctx[:output]).to eq([])
    end
  end
end
