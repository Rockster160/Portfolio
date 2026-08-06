module Buddy
  # What Buddy says it's doing while a turn is still running.
  #
  # A turn can spend several rounds calling tools before a word of the reply
  # exists, and all of that used to sit behind a single "…". These are the
  # lines that go in its place — one per call, in the order they happen, so
  # the wait shows its work instead of just being long.
  #
  # Kept here rather than on each tool because it's presentation, not tool
  # semantics: the phrase is the difference between "print_again" and "asking
  # the printer", and only one of those belongs in front of a person. A tool
  # with no entry falls back to its own name in plain words, so a new one is
  # never blank — just less charming than it could be.
  module Progress
    module_function

    # Housekeeping the model does alongside the real work — setting its own
    # face, jotting a fact down. `set_mood` fires on most turns, and a line
    # reading "Set mood" every time is precisely the noise this is meant to
    # replace, so these pass without a word (see Buddy::SideEffects).
    SILENT = Buddy::SideEffects::NAMES.to_set.freeze

    PHRASES = {
      # Reading
      get_context:           "Checking your day",
      search_events:         "Digging through what you've logged",
      search_agenda:         "Searching your calendar",
      print_history:         "Looking up what you've printed",
      chore_progress:        "Pulling up how the week went",
      check_weather:         "Checking the weather",
      list_reminders:        "Gathering your reminders",
      read_prompt:           "Opening that up",
      view_image:            "Taking another look at that picture",
      read_listener_guide:   "Working out what to watch for",

      # The printer
      print_again:           "Asking the printer",

      # Chores + events
      complete_chore:        "Marking that done",
      undo_chore_completion: "Undoing that one",
      edit_chore_completion: "Fixing that completion",
      create_chore:          "Setting up the chore",
      edit_chore:            "Adjusting the chore",
      log_event:             "Writing that down",
      edit_event:            "Correcting that entry",
      delete_event:          "Removing that entry",

      # Time
      set_timer:             "Starting the timer",
      cancel_timer:          "Stopping the timer",
      schedule_reminder:     "Setting the reminder",
      move_reminder:         "Moving the reminder",
      cancel_reminder:       "Cancelling the reminder",
      remind_when:           "Setting up the watch",

      # Calendar + lists
      add_agenda_item:       "Putting it on your calendar",
      edit_agenda_item:      "Moving it on your calendar",
      add_list_item:         "Adding it to the list",
      edit_list_item:        "Editing the list",
      remove_list_item:      "Taking it off the list",

      # People
      message_partner:       "Passing it along",
      ask_partner:           "Asking them",
      ask_partner_choice:    "Asking them",
      ask_partner_multi:     "Asking them",
      relay_answer:          "Sending your answer back",
      ask_me:                "Writing that up for you",

      # Ideas + prompts
      stash_idea:            "Holding onto that",
      move_idea:             "Filing it somewhere else",
      defer_idea:            "Parking it for later",
      finish_idea:           "Ticking it off",
      drop_idea:             "Letting that go",
      answer_prompt:         "Filling that in",
      skip_prompt:           "Skipping it",

      # Automations
      call_jil_function:     "Running that for you",
      trigger_jil_task:      "Running that for you",
      run_routine:           "Running the routine",
      save_routine:          "Saving the routine",
      forget_routine:        "Forgetting the routine",
      mac_command:           "Talking to the Mac",

      # Everything else
      withdraw_pebbles:      "Counting out your pebbles",
      set_font_size:         "Resizing the text",
      undo:                  "Putting that back",
    }.freeze

    # Nil means say nothing at all. Otherwise a tool with no entry falls back to
    # its own name in plain words: underscores out, first letter up, and nothing
    # else, because a guess that tries to be clever reads worse than a plain one
    # that's obviously mechanical.
    def phrase_for(name)
      key = name.to_s.to_sym
      return nil if SILENT.include?(key)

      PHRASES[key] || key.to_s.tr("_", " ").capitalize
    end
  end
end
