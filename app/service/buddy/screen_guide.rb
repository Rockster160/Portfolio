module Buddy
  # What is actually on the screen, so Buddy can answer "how do I…" instead of
  # refusing to.
  #
  # The rule used to be that Buddy never describes the screen at all — "you
  # don't know, and a confident wrong direction sends someone hunting for
  # something that isn't there" (prod 2612 invented a tab). That was the right
  # rule for a companion with nothing to read. It is the wrong rule now: prod
  # 5808, Eve asked how to stop the notifications, was sent to her phone's
  # settings and offered the sound toggle, and the control she wanted was the
  # bell in the top bar of the window she was typing into.
  #
  # So the refusal is replaced by a source. Three properties make that safe:
  #
  #   1. **Closed list.** Same reason Buddy::AppPages is one - a guessed
  #      control is indistinguishable from a real one until somebody goes
  #      looking for it.
  #   2. **On demand, never prompt-resident.** It is a page of text to answer a
  #      question almost nobody asks on any given day, and the main prompt is
  #      already 140k.
  #   3. **Anchored to the markup.** Every control carries the `data-*`
  #      attribute it is rendered with, and screen_guide_spec asserts each one
  #      still appears in the view. Rename a hook and the spec fails, which is
  #      the only version of "keep it up to date" that survives contact with a
  #      year of edits. `hook` is never shown to the model.
  #
  # Owner-only surfaces are dropped rather than labelled, same as AppPages:
  # Chelsea has no Claude threads, so the working-directory strip is furniture
  # she can see and nothing she can use.
  module ScreenGuide
    module_function

    SURFACES = [
      {
        name:     :top_bar,
        about:    "The strip across the top of the chat window",
        controls: [
          {
            hook:  "data-byte-drawer-toggle",
            label: "The ☰ lines at the far left",
            does:  "Opens the side drawer: every conversation, plus Routines, Reminders and Settings.",
          },
          {
            hook:  "data-byte-actions-toggle",
            label: "The ⚡ lightning bolt",
            does:  "Opens your five buttons. Picking one that has its own options replaces the " \
                   "list with those, and tapping outside closes it.",
          },
          {
            hook:  "data-byte-notify",
            label: "The 🔔 bell",
            does:  "Turns push notifications on and off for this device. THIS is the answer to " \
                   "\"stop alerting me\" - it is not the reminder list, and it is not a phone setting.",
          },
          {
            hook:  "data-byte-mute",
            label: "The 🔈 speaker",
            does:  "Sound only - it silences the timer alarm. It does NOT stop notifications.",
          },
          {
            hook:  "data-byte-reload",
            label: "The ↻ circular arrow",
            does:  "Reloads the app. It grows a dot when a new version is ready to pick up - " \
                   "and if the app is left alone at the bottom of the thread with nothing " \
                   "open, it picks the new version up on its own after a few minutes.",
          },
        ],
      },
      {
        name:     :the_drawer,
        about:    "The panel that slides in from the left",
        controls: [
          {
            hook:  "data-byte-open-routines",
            label: "⚡ Routines",
            does:  "Every saved routine, with the steps in each. Rename, reorder and delete them here.",
          },
          {
            hook:  "data-byte-open-reminders",
            label: "⏰ Reminders",
            does:  "Everything set, one-off and repeating. Tap one to change its time, its wording " \
                   "or how often it repeats, or to cancel it.",
          },
          {
            hook:  "data-byte-open-settings",
            label: "⚙️ Settings",
            does:  "Text size, as − and + either side of the current percentage. You can also just " \
                   "ask for bigger text and it is done from here.",
          },
          {
            hook:  "data-byte-new-convo",
            label: "The + at the top of the conversation list",
            does:  "Starts another conversation.",
          },
        ],
      },
      {
        name:     :the_composer,
        about:    "The box at the bottom where they type",
        controls: [
          {
            hook:  "data-byte-attach",
            label: "The picture button to the right of the box",
            does:  "Attaches a photo. Pasting or dragging one in does the same thing.",
          },
          { hook: "data-byte-send", label: "The ▶ arrow", does: "Sends it." },
          {
            hook:  "data-byte-reply-bar",
            label: "A bar above the box naming a message",
            does:  "Shows up when they are replying to one in particular. The ✕ on it cancels that.",
          },
        ],
      },
      {
        name:     :the_pet,
        about:    "The companion itself, above the conversation",
        controls: [
          {
            hook:  "data-buddy-face-popover",
            label: "Tapping the pet",
            does:  "Opens the face picker - every theme, and the expressions within the one they " \
                   "are on. This is how they change which pet they have.",
          },
          {
            hook:  "data-buddy-timers",
            label: "Chips under the pet",
            does:  "Any timer that is running. Swiping one away cancels it.",
          },
        ],
      },
      {
        name:       :the_working_directory_strip,
        about:      "The thin line under the header, in Claude threads",
        owner_only: true,
        controls:   [
          {
            hook:  "data-byte-pwd-path",
            label: "The path on the left",
            does:  "Which folder the thread is working in, plus the adopted session's name if it has one.",
          },
          {
            hook:  "data-byte-pwd-mode",
            label: "The ask / auto pill",
            does:  "Permission mode. `auto` approves tool calls without prompting; it only appears " \
                   "on Claude threads.",
          },
        ],
      },
    ].freeze

    def for_user(user)
      surfaces = SURFACES.reject { |surface| surface[:owner_only] && !owner?(user) }
      surfaces.map { |surface|
        {
          area:     surface[:name],
          about:    surface[:about],
          controls: surface[:controls].map { |c| { label: c[:label], does: c[:does] } },
        }
      }
    end

    def owner?(user)
      user.respond_to?(:me?) && user.me?
    end

    # Every hook this file claims exists, for the drift spec.
    def hooks
      SURFACES.flat_map { |surface| surface[:controls].pluck(:hook) }
    end
  end
end
