module Buddy
  # A resolve that found several records and no honest way to choose between
  # them. Carries the candidates rather than only the complaint.
  #
  # Raised by a resolver; caught in Buddy::GPT::Turn.resolve_call, which puts
  # the candidates in front of the person as a row of buttons.
  class Ambiguous < StandardError
    # `arg` is the tool argument the choice replaces, so a tap can rebuild the
    # original call with the record they picked. `options` are
    # `{ value:, label:, description: }` - `value` being the exact string that
    # argument wants, which is why an inventory option answers with a #HANDLE
    # and a chore option answers with its name.
    # `message` is for the MODEL and says what to do about it. `prompt` is the
    # sentence a PERSON reads over the buttons, and they are not the same
    # sentence - the chore failure ends "Call again with one of those EXACTLY
    # ... Never substitute another tool for the chore", which is instruction,
    # not a question anyone would ask out loud.
    attr_reader :arg, :options, :prompt

    def initialize(message, arg:, options:, prompt: nil)
      @arg     = arg.to_sym
      @options = Array(options)
      @prompt  = prompt.presence || message
      super(message)
    end
  end
end
