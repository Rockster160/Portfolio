module Buddy
  # Keys a Jil task leaves for Buddy to fill, and running whatever fills them.
  #
  # A task declares one by calling `Buddy.command("Bathroom Button")`. Nothing
  # else registers it: the key exists because a task's code names it, so a key
  # whose task is deleted or switched off stops being offered, and a person
  # can't attach a command to something no task will ever run.
  module Commands
    module_function

    # A literal key: `Buddy.command("Top Button")`. A key built at run time
    # can't be found by reading the code, so it can't be offered either.
    KEY_RX = /Buddy\.command\(\s*"((?:[^"\\]|\\.)+)"/

    # The keys this person's own tasks call, each with the tasks that call it.
    def slots(user)
      tasks = user.tasks.active.enabled.where("code LIKE ?", "%Buddy.command(%")
      found = {}
      tasks.pluck(:name, :code).each { |task_name, code|
        code.to_s.scan(KEY_RX).flatten.each { |key|
          clean = key.gsub(/\\(.)/, "\\1").strip
          next if clean.empty?

          slot = (found[clean.downcase] ||= { name: clean, tasks: [] })
          slot[:tasks] |= [task_name]
        }
      }
      found.values.sort_by { |slot| slot[:name].downcase }
    end

    # The slot they meant: the key itself in any case, or the same words in any
    # order ("button bathroom").
    def slot(user, key)
      wanted = words(key)
      return nil if wanted.empty?

      all = slots(user)
      all.find { |slot| slot[:name].casecmp?(key.to_s.strip) } ||
        all.find { |slot| words(slot[:name]).sort == wanted.sort }
    end

    def words(str)
      str.to_s.downcase.scan(/[a-z0-9]+/)
    end

    # The roster line: each key, and what it does now.
    def roster(user)
      saved = BuddyCommand.where(user: user).index_by { |cmd| cmd.name.downcase }
      slots(user).map { |slot|
        cmd = saved[slot[:name].downcase]
        doing = cmd ? cmd.summary.join(", ") : "nothing yet"
        "#{slot[:name]} (#{doing})"
      }
    end

    # What the seed says when a command saved as words runs. The frame in front
    # of it already says nobody spoke; this says what to do instead.
    SAY_SEED = "%<key>s just ran, and they set it to mean this: \"%<words>s\". Do that now, " \
               "exactly as if they had just asked you, and say briefly what you did.".freeze

    # Runs the command saved under `key` for `user`. False when nothing is
    # saved there, or when this same key is already running further up the
    # stack: a command whose steps fire the task that called it would
    # otherwise call itself until something gave out.
    def run!(user, key)
      cmd = BuddyCommand.named(user, key)
      return false if cmd.nil?

      running = (Thread.current[:buddy_commands_running] ||= [])
      return false if running.include?(cmd.id)

      running << cmd.id
      begin
        conversation = Buddy::CompanionRelay.conversation_for(user)
        cmd.touch_run!
        if cmd.runs_steps?
          Buddy::ProposalBuilder.run_markers!(user: user, conversation: conversation, markers: cmd.markers, body: nil)
        else
          Buddy::CompanionDelivery.deliver_prompt(
            user:         user,
            conversation: conversation,
            seed:         format(SAY_SEED, key: cmd.name, words: cmd.say),
            metadata:     { kind: :buddy_trigger, hidden: true, source: :jil_command },
          )
        end
        true
      ensure
        running.delete(cmd.id)
      end
    end
  end
end
