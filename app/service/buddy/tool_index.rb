module Buddy
  # The tools Buddy is offered, in two stages.
  #
  # Every registry tool used to ship its full schema on every model call -
  # eighty-odd descriptions, ~200KB of JSON, most of the input tokens of a turn
  # that only wanted to say hello. A long description is not the same thing as
  # a findable one, either: the edge probes keep catching the right tool lost
  # in the pile.
  #
  # So a turn starts with the FRAME (the read tools and silent side effects the
  # Turn answers itself), the registry tools marked `always:`, and every other
  # tool under its own name with only its one-line `summary` and no arguments.
  # The model picks from that list the way it picks any tool - by name - and
  # calling one OPENS it: nothing runs, its full schema takes the summary's
  # place for the rest of the turn, and the model makes the real call next.
  #
  # The summaries used to sit inside the description of a single `load_tools`
  # function instead. The model reads a tool list by its names, so it saw one
  # vague "load" tool beside `get_context` and reached for `get_context`: a
  # third of the eval probes never selected anything at all.
  #
  # Nothing here knows any tool by name. Which side of the line a tool sits on
  # is the `always:` it registered with, and what its entry says is its own
  # `summary:`.
  module ToolIndex
    module_function

    # A round spent only opening tools doesn't count toward Turn::MAX_ROUNDS -
    # it bought nothing the person can see. Capped, so a model that keeps
    # opening more can't spend the turn reading manuals.
    MAX_LOAD_ROUNDS = 2

    # Everything a turn can be offered, in full - the shape before the index,
    # and still the shape a seed that names its tools gets (see
    # Turn#seed_tools), since those are already narrowed to a handful.
    def everything(user:)
      [*frame(user), *Buddy::Tools.function_schemas(user: user)]
    end

    # The first stage, with whatever has been opened since in full. Each tool
    # keeps its place in the list whether it's a summary or a schema, so the
    # list only changes from the first one opened onward.
    def schemas(user:, loaded: [])
      wanted = loaded.to_set(&:to_sym)
      [
        *frame(user),
        *Buddy::Tools.offered(user: user).map { |tool|
          next Buddy::Tools.function_schema(tool, user: user) if Buddy::Tools.always?(tool)
          next Buddy::Tools.function_schema(tool, user: user) if wanted.include?(tool[:name])

          entry(tool)
        },
      ]
    end

    # The tools the Turn answers itself. Small, and needed on turns that never
    # act at all, so they're never behind the index.
    def frame(user)
      [
        Buddy::GPT::ContextTool.schema(user: user, briefing: false),
        Buddy::GPT::PromptTool.schema,
        Buddy::GPT::ImageTool.schema,
        Buddy::GPT::ListenerTool.schema,
        *Buddy::SideEffects.function_schemas,
      ]
    end

    def indexed(user:)
      Buddy::Tools.offered(user: user).reject { |tool| Buddy::Tools.always?(tool) }
    end

    # A tool before it's opened: its name and when to reach for it. No
    # arguments, so a call can only ever mean "this one" and never runs.
    def entry(tool)
      {
        type:        :function,
        name:        tool[:name],
        description: tool[:summary].to_s,
        strict:      true,
        parameters:  { type: :object, properties: {}, required: [], additionalProperties: false },
      }
    end

    # Whether this call is a tool being picked rather than used: one on the
    # index, not opened yet this turn, and called with nothing - which is all
    # its entry lets it carry. A call that does arrive with arguments is the
    # tool being used, and runs.
    def opening?(name, args, loaded:)
      tool = Buddy::Tools[name]
      return false if tool.nil? || Buddy::Tools.always?(tool) || loaded.include?(tool[:name])

      args.blank? || (args.respond_to?(:values) && args.values.all?(&:blank?))
    end

    # Opens it for the rest of the turn (`loaded` is a Set the caller keeps)
    # and says so. "Nothing has happened" is the half that matters: the model
    # called the thing it wanted, and must not tell them it's done.
    def open(name, loaded:)
      loaded << name.to_s.to_sym
      {
        opened: name.to_s,
        how:    "Nothing has happened yet - this only opened it. Its full instructions and arguments " \
                "are in your tool list now: read them and call #{name} again with its arguments, on " \
                "this round. Don't tell them you're looking.",
      }
    end
  end
end
