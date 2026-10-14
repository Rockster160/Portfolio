class Jil::Methods::Base
  # Auth types that name the PERSON who set the execution off, and how to get
  # from `auth_type_id` to them - see the note on Execution's enum. Every other
  # type carries a task id, an API key id, or nothing, so nobody but the owner
  # is involved and the owner check is the whole answer for those.
  #
  # Here rather than on one method class because it is a fact about the
  # EXECUTION, and because the two methods that reach the desk Mac both need
  # the same answer - a second copy of this table is a second chance to get it
  # wrong.
  ACTOR_FROM_AUTH = {
    guest:    ->(id) { ::User.find_by(id: id) },
    userpass: ->(id) { ::User.find_by(id: id) },
    run:      ->(id) { ::User.find_by(id: id) },
    jwt:      ->(id) { ::User.find_by(id: id) },
    buddy:    ->(id) { ::User.find_by(id: id) },
    agenda:   ->(id) { ::AgendaItem.find_by(id: id)&.user },
  }.freeze

  attr_accessor :jil

  def cast(value)
    raise NotImplementedError, "[#{self.class}] does not implement `cast`"
  end

  def initialize(jil, ctx=nil)
    @jil = jil
    @ctx = ctx || jil.ctx
  end

  def evalarg(arg, passed_ctx=nil)
    if arg.is_a?(::Jil::Parser) || arg.is_a?(::Array)
      @jil.execute_block(arg, passed_ctx || @ctx || @jil.ctx)
    elsif arg.is_a?(::String) && !arg.match?(/^".*?"$/m)
      token_val(arg)
    elsif arg.is_a?(::String) && arg.match?(/^".*?"$/m)
      parse_unwrap_string(arg)
    else
      arg
    end
  end

  def parse_unwrap_string(arg)
    return "\n" if arg == "\"\\\\n\"" # Hacky hacky to fix joining/splitting by newlines

    unwrap = arg[1..-2]
    escaped = unwrap.gsub(/\\n/, "\\\\\n") # Raw new lines from textareas
    unescaped = escaped.gsub(/\\+/) { |f| "\\" * (f.length - 1) }
    unescaped.gsub(/\#\{\s*(.*?)\s*\}/) { |_found|
      @jil.cast(token_val(Regexp.last_match[1]), :String)
    }
  end

  def evalargs(args)
    Array.wrap(args)
      .reject { |arg| arg.is_a?(::Jil::Parser) && (arg.commented? || arg.inline_comment?) }
      .map { |arg|
        if arg.is_a?(::Array)
          evalargs(arg)
        else
          evalarg(arg)
        end
      }
  end

  def token_val(token)
    unless @jil.ctx&.dig(:vars)&.key?(token.to_sym)
      raise ::Jil::ExecutionError,
        "Unfound token `#{token}`"
    end

    @jil.ctx&.dig(:vars, token.to_sym, :value)
  end

  def token_class(token)
    return @jil.ctx&.dig(:vars, token.to_sym, :class) if @jil.ctx&.dig(:vars)&.key?(token.to_sym)

    token
  end

  def base_execute(line)
    case line.methodname
    when :new then respond_to?(:init) ? init(line) : cast(evalarg(line.arg))
    when :inspect
      token_val(line.objname).tap { |str|
        @jil.ctx[:output] << "[#{line.objname}]#{::Jil::Methods::String.new(@jil, @ctx).cast(str).gsub(
          /^"|"$/, ""
        )}"
      }
    when :presence
      token_val(line.objname).presence
    else
      respond_to?(:execute) ? execute(line) : fallback(line)
    end
  end

  def fallback(line)
    if line.objname.match?(/^[A-Z]/)
      send(line.methodname, *evalargs(line.args))
    elsif respond_to?(line.methodname)
      send(line.methodname, token_val(line.objname), *evalargs(line.args)).tap { |new_val|
        set_value(line.objname, new_val) if line.methodname.ends_with?("!")
      }
    else
      token_val(line.objname).send(line.methodname, *evalargs(line.args))
    end
  end

  # BOTH have to be me: the task is mine AND the person who set it off is me.
  # What anything reaching one person's own machine has to ask.
  #
  # The owner check alone is not enough, because `@jil.user` is the task's
  # OWNER and not necessarily whoever asked. A SHARED task always runs as its
  # owner - that's `Task#execute` calling `Jil::Executor.call(user, ...)`, and
  # it's deliberate, since running as the owner is how a task reaches their
  # credentials at all. So anybody else pressing Run on the owner's task, or
  # asking their companion to fire one, arrives with `@jil.user` already set to
  # the owner. Checking only the owner would let them drive his machine.
  #
  # The execution knows who asked: `auth_type_id` names the acting person for
  # the types above (the same fact `Jil::Methods::Buddy#recipient` reads to
  # answer the right person). Nothing to read means nobody but the owner is
  # involved - cron, a `tell:`, a devExec script - and the owner is the answer.
  # An actor-bearing execution that can't name its actor fails CLOSED.
  #
  # One gap, stated rather than papered over: a trigger CHAIN loses the actor.
  # `Global.triggerNow` re-fires as the owner with `auth: :trigger` and a TASK
  # id, so a shared task that triggers another task that reaches the Mac still
  # gets there. Closing that means carrying the actor through ScheduledTrigger,
  # which is a change to every trigger path rather than to one method - so
  # don't share a task that reaches the Mac, directly or down a chain.
  def owned_and_run_by_me?
    return false unless @jil.user&.me?

    execution = @jil.execution
    finder = ACTOR_FROM_AUTH[execution&.auth_type&.to_sym]
    return true if finder.nil?

    finder.call(execution.auth_type_id)&.me? || false
  end

  def set_value(token, val, type: nil)
    token = token.to_s.to_sym
    @jil.ctx[:vars][token] ||= { class: type || :Any, value: val }
    @jil.ctx[:vars][token][:class] = type if type
    @jil.ctx[:vars][token][:value] = val
  end
end
