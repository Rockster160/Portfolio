require "rails_helper"

RSpec.describe ProxyRequest, "#diagnose" do
  subject(:diag) { ProxyRequest.new }

  before do
    allow(DataStorage).to receive(:[]).with(:local_ip).and_return("97.117.17.133")
    # Happy-path stubs; individual examples override the layer under test.
    allow(diag).to receive(:ping_host).and_return(true)
    allow(diag).to receive(:tcp_error).and_return(nil)
    allow(diag).to receive(:http_test).and_return(%({"success":true}))
  end

  # `diagnose` narrates to stdout, and every example below reads that narration
  # through RSpec's `output` matcher. A helper by that name here shadows the
  # matcher - `output(/regex/)` resolved to the helper, which takes no
  # arguments, and all six of those examples died on ArgumentError before
  # reaching an assertion.
  it "reports all layers healthy when every check passes" do
    expect { expect(diag.diagnose).to eq(ok: true, failed_at: nil) }.to output.to_stdout
  end

  it "stops at :config when local_ip is unset" do
    allow(DataStorage).to receive(:[]).with(:local_ip).and_return(nil)
    result = nil
    expect { result = diag.diagnose }.to output(/DataStorage\[:local_ip\] is blank/).to_stdout
    expect(result[:failed_at]).to eq(:config)
  end

  it "stops at :ping and blames the pre-router path when ICMP fails" do
    allow(diag).to receive(:ping_host).and_return(false)
    expect { @r = diag.diagnose }.to output(/public IP doesn't answer|CGNAT/).to_stdout
    expect(@r[:failed_at]).to eq(:ping)
  end

  it "stops at :tcp with the dead port-forward remediation on EHOSTUNREACH" do
    allow(diag).to receive(:tcp_error).and_return(Errno::EHOSTUNREACH.new("No route to host"))
    text = nil
    expect { diag.diagnose }.to output(satisfy { |s| text = s; true }).to_stdout
    expect(text).to match(/dead port-forward|no device currently holds/)
    expect(text).to match(/wired interface must be .*active/)
    expect(diag.diagnose[:failed_at]).to eq(:tcp)
  end

  it "stops at :tcp with the relay-down remediation on ECONNREFUSED" do
    allow(diag).to receive(:tcp_error).and_return(Errno::ECONNREFUSED.new("Connection refused"))
    text = nil
    expect { diag.diagnose }.to output(satisfy { |s| text = s; true }).to_stdout
    expect(text).to match(/Ruby relay is down/)
    expect(text).to match(/kickstart -k gui\/\$UID\/com\.ardesian\.tesla-ruby-relay/)
  end

  it "stops at :tcp with the filtered/timeout remediation on ETIMEDOUT" do
    allow(diag).to receive(:tcp_error).and_return(Errno::ETIMEDOUT.new("timed out"))
    expect { @r = diag.diagnose }.to output(/silently dropped|filtering/).to_stdout
    expect(@r[:failed_at]).to eq(:tcp)
  end

  it "stops at :http and blames the app behind the socket when /test is wrong" do
    allow(diag).to receive(:http_test).and_return("ERROR: Errno::ECONNRESET: reset")
    # Case-insensitive: it's the presence of the remediation being asserted,
    # not whether the bullet happens to start with a capital.
    expect { @r = diag.diagnose }.to output(/kickstart BOTH launchd jobs/i).to_stdout
    expect(@r[:failed_at]).to eq(:http)
  end
end
