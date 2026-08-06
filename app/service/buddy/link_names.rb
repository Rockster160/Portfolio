module Buddy
  # Settling a link endpoint's name at the moment the link is made.
  #
  # The runtime match is literal by design, so a name stored slightly wrong is a
  # link that never fires and never complains. The chore end can be checked
  # against real records, so it is: "coffee run" becomes "Coffee Run" here,
  # once, rather than missing forever.
  #
  # Events, agenda tasks and list items are NOT resolved. An event name is
  # whatever gets typed at log time and may not exist yet; a list item usually
  # doesn't exist until the chore comes due. Guessing at those would be
  # inventing, so they're stored exactly as given and the manager flags an end
  # that points nowhere.
  #
  # Lives here rather than in the tool file because a tool file is `load`ed on
  # every reload, and anything defined in one gets redefined with it.
  module LinkNames
    module_function

    def resolve(name, kind, ctx)
      text = name.to_s.strip
      return text unless kind.to_s == "chore"
      return text unless ctx.respond_to?(:resolve_chore)

      ctx.resolve_chore(text)&.name.presence || text
    end
  end
end
