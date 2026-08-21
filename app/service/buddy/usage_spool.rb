module Buddy
  # Spend that happened somewhere other than production, held in a file until it
  # can be handed over.
  #
  # Evals and an afternoon of poking Byte on localhost are billed to the same
  # account as everything the person actually uses, but they land in whichever
  # database the laptop is pointed at, so `buddy:cost` in production has always
  # under-reported the real number. Nothing local can write to the production
  # database directly, and nothing should have to: each call appends a line
  # here, and `bx rails buddy:usage_sync` hands the file over when there is a
  # connection to hand it over on.
  #
  # The line carries where it came from — the machine, the environment, and the
  # kind of call — so the merged total can still be taken apart afterwards.
  module UsageSpool
    module_function

    DIR     = "log/buddy_usage".freeze
    PENDING = "pending.jsonl".freeze
    ORIGIN  = "origin".freeze

    def dir
      Rails.root.join(ENV["BUDDY_USAGE_SPOOL_DIR"].presence || DIR)
    end

    def path
      dir.join(PENDING)
    end

    # Production writes straight to the database everything else is trying to
    # reach, so it has nothing to spool.
    #
    # The suite is left out for a different reason: its token counts come from
    # the fake client, which invents them. They are recorded locally so the
    # environment breakdown is complete, but no money was spent and production's
    # total must not say otherwise. `BUDDY_USAGE_SPOOL=1` overrides that for a
    # run that really does call the API.
    def spool?
      return ENV["BUDDY_USAGE_SPOOL"] != "0" if ENV["BUDDY_USAGE_SPOOL"].present?

      !Rails.env.production? && !Rails.env.test?
    end

    # Never let accounting take a turn down with it.
    def append!(usage)
      return nil if usage.nil? || !spool?
      return nil if usage.origin_uid.present? # already someone else's row

      write(line(usage))
    rescue StandardError => e
      Rails.logger.warn("[Buddy::UsageSpool] append failed: #{e.class}: #{e.message}")
      nil
    end

    # `byte_message_id` and `byte_conversation_id` are deliberately absent: those
    # ids mean something else in the database this is headed for, and a spend
    # record pointed at the wrong conversation is worse than one pointed at none.
    def line(usage)
      {
        origin_uid:          uid_for(usage),
        env:                 usage.env,
        kind:                usage.kind,
        model:               usage.model,
        input_tokens:        usage.input_tokens,
        cached_input_tokens: usage.cached_input_tokens,
        output_tokens:       usage.output_tokens,
        reasoning_tokens:    usage.reasoning_tokens,
        cost_micros:         usage.cost_micros,
        username:            usage.user&.username,
        recorded_at:         usage.created_at.utc.iso8601,
      }
    end

    # Machine, environment, row, and the moment it was written. The timestamp is
    # in there because a row id is only unique while the row exists: the eval
    # harness rolls its work back, and the next real call can be handed the id
    # that just went away. Two rows sharing a uid means the second one is thrown
    # out at the far end as a repeat, which is money quietly disappearing.
    def uid_for(usage)
      "#{origin_id}:#{usage.env}:#{usage.id}:#{usage.created_at.utc.iso8601(3)}"
    end

    # One id per checkout rather than per database, so dropping and reloading the
    # development database can't hand a fresh row the uid of one already synced.
    def origin_id
      @origin_id ||= {}
      @origin_id[dir.to_s] ||= read_origin_id || write_file(dir.join(ORIGIN), SecureRandom.uuid)
    end

    def read_origin_id
      file = dir.join(ORIGIN)
      file.exist? ? file.read.strip.presence : nil
    end

    def pending
      return [] unless path.exist?

      path.readlines.filter_map { |raw|
        next if raw.blank?

        JSON.parse(raw, symbolize_names: true)
      }
    end

    def pending_count
      pending.length
    end

    # Everything this checkout has ever written down, waiting or handed over.
    # A backfill compares against it so a second run doesn't send the same
    # afternoon twice.
    def spooled_uids
      files = Dir[dir.join("synced", "*.jsonl").to_s].map { |name| Pathname.new(name) }
      files.unshift(path) if path.exist?
      files.flat_map { |file|
        file.readlines.filter_map { |raw|
          next if raw.blank?

          JSON.parse(raw, symbolize_names: true)[:origin_uid]
        }
      }.to_set
    end

    # Called once the whole file is known to have landed. Kept rather than
    # deleted: it is the only local record of what was handed over.
    def archive!(stamp)
      return nil unless path.exist?

      target = dir.join("synced", "#{stamp}.jsonl")
      FileUtils.mkdir_p(target.dirname)
      FileUtils.mv(path.to_s, target.to_s)
      target
    end

    def write(payload)
      FileUtils.mkdir_p(dir)
      File.open(path, File::WRONLY | File::APPEND | File::CREAT) { |file|
        file.flock(File::LOCK_EX)
        file.puts(payload.to_json)
      }
      payload
    end

    def write_file(file, contents)
      FileUtils.mkdir_p(file.dirname)
      File.write(file, contents)
      contents
    end
  end
end
