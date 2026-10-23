module Buddy
  # The reminders and watches one request turned into, held together as ONE
  # thing.
  #
  # "When the garage opens after ten, tell me, and check again at midnight"
  # becomes a watch, a reminder and maybe the watch that stops it - separate
  # rows, each with its own id, and changing the request used to mean finding
  # and poking each of them in turn. Every row made while one reply's calls
  # run carries the same `plan_id`, so the request can be seen, changed and
  # cancelled whole.
  #
  # The id is the reply's message id. Nothing about a plan needs storing beyond
  # which rows share it, and a reply is exactly the unit a request arrives in.
  module Plan
    module_function

    KEY = :buddy_plan_id

    # Rows created inside the block join this plan. Re-entrant: a reply that
    # runs a routine is still one request, so an inner call keeps the outer id.
    def within(byte_message)
      return yield if byte_message.nil? || current_id

      begin
        Thread.current[KEY] = "p#{byte_message.id}"
        yield
      ensure
        Thread.current[KEY] = nil
      end
    end

    def current_id
      Thread.current[KEY]
    end

    # Everything still live in a plan: reminders that haven't finished and
    # watches still armed, the panel's switched-off ones included, since they
    # can still be changed or removed.
    def parts(user, plan_id)
      return [] if plan_id.blank?

      [
        *BuddyReminder.where(user_id: user.id, plan_id: plan_id, fired_at: nil).order(:fire_at, :id).to_a,
        *BuddyWatch.where(user_id: user.id, plan_id: plan_id, fired_at: nil).order(:id).to_a,
      ]
    end

    # A plan worth naming as one: more than one row. A lone reminder is just a
    # reminder and already has its own id everywhere it's shown.
    def multi?(user, plan_id)
      parts(user, plan_id).length > 1
    end

    # Every plan id with more than one live row, in two queries, for anything
    # tagging a list of rows with the plan each belongs to.
    def shared_ids(user)
      counts = Hash.new(0)
      [BuddyReminder, BuddyWatch].each { |klass|
        klass.where(user_id: user.id, fired_at: nil).where.not(plan_id: nil).group(:plan_id).count.each { |pid, n|
          counts[pid] += n
        }
      }
      counts.select { |_pid, n| n > 1 }.keys.to_set
    end

    # Which plan they mean: the plan id, or words from any of its rows. Raises
    # with the choices rather than guessing, because editing the wrong plan
    # moves reminders they didn't mention.
    def find!(user, needle)
      wanted = needle.to_s.strip
      raise "which plan?" if wanted.empty?

      ids = (
        if wanted.match?(/\Ap\d+\z/i)
          [wanted.downcase]
        else
          words = wanted.downcase
          rows = live(user).select { |row|
            [row.body, (row.metadata.to_h["human_when"] if row.respond_to?(:metadata))].compact.join(" ").downcase.include?(words)
          }
          rows.map(&:plan_id)
        end
      ).compact.uniq
      raise "nothing matches #{wanted.inspect} - it may have finished already" if ids.empty?
      if ids.length > 1
        raise "#{ids.length} plans match - say which: #{ids.map { |pid| "#{pid} (#{summary(user, pid)})" }.join("; ")}"
      end

      ids.first
    end

    def live(user)
      [
        *BuddyReminder.where(user_id: user.id, fired_at: nil).where.not(plan_id: nil).to_a,
        *BuddyWatch.where(user_id: user.id, fired_at: nil).where.not(plan_id: nil).to_a,
      ]
    end

    # One line naming every part, in the words each one already uses.
    def summary(user, plan_id)
      summary_of(parts(user, plan_id), user)
    end

    def summary_of(rows, user)
      rows.map { |row| part_phrase(row, user) }.to_sentence
    end

    def part_phrase(row, user)
      body = row.body.to_s.truncate(40)
      return "stop rule #{row.metadata.to_h["human_when"]}".squish if row.is_a?(BuddyWatch) && row.cancels?
      return "\"#{body}\" #{row.metadata.to_h["human_when"]}".squish if row.is_a?(BuddyWatch)

      at = row.fire_at && Buddy::TimeParser.friendly(row.fire_at, user: user)
      "\"#{body}\"#{" at #{at}" if at}"
    end
  end
end
