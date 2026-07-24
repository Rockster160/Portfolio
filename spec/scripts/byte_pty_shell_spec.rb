require "rails_helper"

require Rails.root.join("_scripts/byte/pty_shell")

# Real-shell integration test — spins up a per-example zsh under PTY,
# runs a couple of commands, and asserts the persistent-session
# protocol (exit code + pwd captured, cwd changes stick, second command
# runs against the same shell).
RSpec.describe PtyShell do
  # Give every example its own conversation id so we don't share the
  # module-level SESSIONS table across tests.
  let(:conversation_id) { "spec-#{rand(10_000_000)}" }
  let(:initial_cwd)     { Dir.tmpdir }

  around do |example|
    example.run
  ensure
    # Reap any session spawned during the example so tests stay hermetic
    # and don't leak long-lived zsh processes.
    if PtyShell::SESSIONS[conversation_id]
      PtyShell::SESSIONS[conversation_id].close
      PtyShell::SESSIONS.delete(conversation_id)
    end
  end

  it "runs a command, captures its output + exit code + cwd", :slow do
    session = PtyShell.session_for(conversation_id, initial_cwd: initial_cwd)
    result  = PtyShell.run(session, conversation_id, initial_cwd, "echo hello-world")

    expect(result[:output]).to include("hello-world")
    expect(result[:exit_status]).to eq(0)
    expect(result[:cwd]).to eq(initial_cwd)
  end

  it "reports the non-zero exit code from a failing command", :slow do
    session = PtyShell.session_for(conversation_id, initial_cwd: initial_cwd)
    result  = PtyShell.run(session, conversation_id, initial_cwd, "false")
    expect(result[:exit_status]).to eq(1)
  end

  it "keeps cwd across two commands in the same session", :slow do
    session = PtyShell.session_for(conversation_id, initial_cwd: initial_cwd)
    PtyShell.run(session, conversation_id, initial_cwd, "cd /")
    result = PtyShell.run(session, conversation_id, initial_cwd, "pwd")
    expect(result[:output]).to include("/")
    expect(result[:cwd]).to eq("/")
  end

  it "reuses the same session process across two session_for calls", :slow do
    s1 = PtyShell.session_for(conversation_id, initial_cwd: initial_cwd)
    s2 = PtyShell.session_for(conversation_id, initial_cwd: initial_cwd)
    expect(s2.pid).to eq(s1.pid)
  end
end
