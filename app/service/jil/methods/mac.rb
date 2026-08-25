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

  # Auth types that name the PERSON who set the execution off, and how to get
  # from `auth_type_id` to them — see the note on Execution's enum. Every other
  # type carries a task id, an API key id, or nothing, so nobody but the owner
  # is involved and the owner check is the whole answer for those.
  ACTOR_FROM_AUTH = {
    guest:    ->(id) { ::User.find_by(id: id) },
    userpass: ->(id) { ::User.find_by(id: id) },
    run:      ->(id) { ::User.find_by(id: id) },
    jwt:      ->(id) { ::User.find_by(id: id) },
    buddy:    ->(id) { ::User.find_by(id: id) },
    agenda:   ->(id) { ::AgendaItem.find_by(id: id)&.user },
  }.freeze

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

  # Both have to be me: the task is mine AND the person who set it off is me.
  #
  # The owner check alone is not enough, because `@jil.user` is the task's OWNER
  # and not necessarily whoever asked. A SHARED task always runs as its owner —
  # that's `Task#execute` calling `Jil::Executor.call(user, ...)`, and it's
  # deliberate, since running as the owner is how a task reaches his
  # credentials at all. So Eve pressing Run on a task of mine, or asking her
  # companion to fire one, arrives here with `@jil.user` already me. Checking
  # only the owner would let her darken my screens.
  #
  # The execution knows who asked: `auth_type_id` names the acting person for
  # the types above (the same fact `Jil::Methods::Buddy#recipient` reads to
  # answer the right person). Nothing to read means nobody but the owner is
  # involved — cron, a `tell:`, a devExec script — and the owner is the answer.
  # An actor-bearing execution that can't name its actor fails CLOSED.
  #
  # One gap, stated rather than papered over: a trigger CHAIN loses the actor.
  # `Global.triggerNow` re-fires as the owner with `auth: :trigger` and a TASK
  # id, so a shared task that triggers another task that runs a Mac command
  # still reaches it. Closing that means carrying the actor through
  # ScheduledTrigger, which is a change to every trigger path rather than to
  # this one — so don't share a task that fires a Mac command, directly or
  # down a chain.
  def permitted?
    return false unless @jil.user&.me?

    execution = @jil.execution
    finder = ACTOR_FROM_AUTH[execution&.auth_type&.to_sym]
    return true if finder.nil?

    finder.call(execution.auth_type_id)&.me? || false
  end
end
