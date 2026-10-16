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
  # Turn answers itself), the registry tools marked `always:`, and one more
  # function, `load_tools`, whose description is the index: every other tool's
  # name and its one-line `summary`. Calling it puts those tools' full schemas
  # into the tool list for the rest of the turn, and the model makes the real
  # call on the next round with the whole instructions in front of it.
  #
  # Nothing here knows any tool by name. Which side of the line a tool sits on
  # is the `always:` it registered with, and what the index says about it is
  # its own `summary:`.
  module ToolIndex
    module_function

    NAME = :load_tools

    # A round spent only loading doesn't count toward Turn::MAX_ROUNDS - it
    # bought nothing the person can see. Capped, so a model that keeps asking
    # for more can't spend the turn reading manuals.
    MAX_LOAD_ROUNDS = 2

    INTRO = <<~TXT.freeze
      Load the full instructions for the tools you need, before calling them. Only the tools already in your list can be called straight away; everything below is listed by name and when to reach for it, and its arguments and rules arrive when you load it. Pick by what they asked for, load every tool the request needs in ONE call (an action and the lookup it depends on, or two tools you're torn between), then call them on the next round. Loading is silent and costs nothing they see, so never tell them you're looking something up. Don't load a tool for something you can answer from what you already have.
    TXT

    # Everything a turn can be offered, in full - the shape before the index,
    # and still the shape a seed that names its tools gets (see
    # Turn#seed_tools), since those are already narrowed to a handful.
    def everything(user:)
      [*frame(user), *Buddy::Tools.function_schemas(user: user)]
    end

    # The first stage, plus whatever has been loaded since. Loaded tools come
    # after the fixed part and in name order, so the prefix every turn starts
    # with is byte-identical and stays cached.
    def schemas(user:, loaded: [])
      offered = Buddy::Tools.offered(user: user)
      always, indexed = offered.partition { |tool| Buddy::Tools.always?(tool) }
      wanted = loaded.to_set(&:to_sym)
      opened = indexed.select { |tool| wanted.include?(tool[:name]) }
      [
        *frame(user),
        *always.map { |tool| Buddy::Tools.function_schema(tool, user: user) },
        (schema(indexed) if indexed.any?),
        *opened.map { |tool| Buddy::Tools.function_schema(tool, user: user) },
      ].compact
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

    def schema(indexed)
      lines = indexed.map { |tool| "- #{tool[:name]}: #{tool[:summary]}" }
      {
        type:        :function,
        name:        NAME,
        description: "#{INTRO.strip}\n\n#{lines.join("\n")}",
        strict:      true,
        parameters:  {
          type:                 :object,
          properties:           {
            names: {
              type:        :array,
              items:       { type: :string, enum: indexed.map { |tool| tool[:name].to_s } },
              description: "Every tool this request needs, by name from the list",
            },
          },
          required:             [:names],
          additionalProperties: false,
        },
      }
    end

    def handles?(name)
      name.to_s.to_sym == NAME
    end

    # Adds the named tools to `loaded` (a Set the caller keeps for the turn)
    # and says what happened. A name that isn't on this person's index is
    # reported rather than dropped, so the model can pick again instead of
    # calling something that will never arrive.
    def load(args, user:, loaded:)
      names     = Array((args || {})[:names] || (args || {})["names"]).map { |name| name.to_s.strip.to_sym }.uniq
      available = indexed(user: user).pluck(:name)
      found, unknown = names.partition { |name| available.include?(name) }
      loaded.merge(found)

      {
        ok:      found.any?,
        loaded:  found,
        unknown: unknown.presence,
        how:     (
          if found.any?
            "Their full instructions and arguments are in your tool list now. Read them and make the " \
              "call on this round - don't tell them you're looking."
          else
            "None of those are on the list. Pick from the names in load_tools' description, or answer " \
              "without a tool."
          end
        ),
      }.compact
    end

    # A registry tool that was called without being loaded first. The model
    # can only name a tool it has seen, so this is one it picked off the index
    # and called on the summary alone. It runs as normal - the arguments are
    # validated the same either way, and a bad call comes back as the usual
    # error - and it's loaded so the next round holds its real schema.
    #
    # True when this call is what loaded it, which is what tells the caller a
    # failure may only be for want of the instructions.
    def called(name, loaded:) # rubocop:disable Naming/PredicateMethod -- it loads; `?` would imply a query
      tool = Buddy::Tools[name]
      return false if tool.nil? || Buddy::Tools.always?(tool) || loaded.include?(tool[:name])

      loaded << tool[:name]
      true
    end

    UNREAD_RETRY = "You called this without loading it, so you hadn't seen its instructions. " \
                   "They're in your tool list now - read them and call it again.".freeze
  end
end
