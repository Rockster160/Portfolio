class Jil::Methods::Mac < Jil::Methods::Base
  # Runs one of the named commands on the desk Mac — the same allowlist Byte's
  # `mac_command` tool uses, reached the same way. Rails only ever sends the
  # NAME; what it maps to lives on the Mac (`~/code/Byte/mac_commands.rb`) and
  # never crosses the wire, because that server is port-forwarded from the
  # internet and an endpoint taking a shell string would be remote code
  # execution behind a shared secret.
  #
  # Adding a command is now three edits: the Mac's registry,
  # `ByteLocal::MAC_COMMANDS`, and the `[Mac]` enum in
  # `app/service/jil/schema.txt`. The schema is read as a flat file, so it can't
  # derive the list; `spec/service/jil/methods/mac_spec.rb` fails when the two
  # Rails-side copies drift.
  #
  # Owner-only, matching Buddy's `mac` feature (Buddy::Features::OWNER_ONLY):
  # it is one person's machine, not a house automation. See `permitted?` — that
  # takes two checks, not one.

  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Mac]
  #   #run(["dark_monitors" "mac_ping"])::Hash

  # Hands back the Mac's own answer — `{ ok:, name:, output:, exit_status: }` —
  # so a task can branch on `ok` and read `output` (which is the entire point of
  # a command like `mac_ping`). A sleeping Mac, an unknown name and a command
  # that exited non-zero all come back as `ok: false` with `error` set, rather
  # than raising: the task carries on, and nothing here reports a success it
  # never got.
  def run(name)
    return { ok: false, name: name.to_s, error: "not authorized" } unless permitted?

    ::ByteLocal.run_command(name.to_s)
  rescue StandardError => e
    ::PrettyLogger.error("[JIL MAC] run #{name}: #{e.class}: #{e.message}")
    { ok: false, name: name.to_s, error: e.message }
  end

  private

  # Both have to be me, which is two checks and not one - see
  # `Jil::Methods::Base#owned_and_run_by_me?`, which is where it lives because
  # `Interview.prep` reaches the same machine and has to ask the same question.
  def permitted?
    owned_and_run_by_me?
  end
end
