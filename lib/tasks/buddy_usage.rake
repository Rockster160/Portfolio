namespace :buddy do
  # Spend that happened on the laptop and belongs in the same total as
  # everything else. Evals and an afternoon of poking Byte on localhost are
  # billed to the same account as everything the person actually uses, but they
  # land in whichever database the laptop is pointed at, so production's number
  # has always been short by however much local work went on.
  #
  #   bx rails buddy:usage_spool     — what is waiting to be handed over
  #   bx rails buddy:usage_sync      — hand it over
  #   bx rails buddy:usage_backfill  — put rows this database already has into the spool

  desc "Show the local Buddy spend waiting to be synced to production"
  task usage_spool: :environment do
    rows  = Buddy::UsageSpool.pending
    money = ->(micros) { Buddy::GPT::Pricing.format_micros(micros) }

    if rows.empty?
      puts "Nothing waiting. (#{Buddy::UsageSpool.path})"
      next
    end

    total = rows.sum { |row| row[:cost_micros].to_i }
    puts "#{rows.length} calls waiting — #{money.call(total)}"
    puts "  #{Buddy::UsageSpool.path}"
    puts "  origin #{Buddy::UsageSpool.origin_id}"

    rows.group_by { |row| [row[:env], row[:kind]] }.sort.each { |(env, kind), group|
      spend = group.sum { |row| row[:cost_micros].to_i }
      puts format("  %-12s %-10s %5d calls %10s", env, kind, group.length, money.call(spend))
    }

    span = rows.filter_map { |row| row[:recorded_at] }.minmax
    puts "  #{span.first} .. #{span.last}" if span.compact.any?
  end

  desc "Send the spooled local Buddy spend to production"
  task :usage_sync, [:batch] => :environment do |_t, args|
    abort "Production writes its own usage rows — nothing to sync." if Rails.env.production?

    waiting = Buddy::UsageSpool.pending
    if waiting.empty?
      puts "Nothing waiting. (#{Buddy::UsageSpool.path})"
      next
    end

    size  = (args[:batch].presence || Buddy::UsageSync::BATCH).to_i
    money = ->(micros) { Buddy::GPT::Pricing.format_micros(micros) }
    total = waiting.sum { |row| row[:cost_micros].to_i }
    puts "Sending #{waiting.length} calls (#{money.call(total)}) to #{ProdApi::PROD_URL} in batches of #{size}..."

    result = (
      begin
        Buddy::UsageSync.call(batch: size) { |index, data|
          landed = "#{data[:created].to_i} created, #{data[:duplicate].to_i} already there"
          puts "  batch #{index}: #{landed}, #{data[:skipped].to_i} skipped"
        }
      rescue StandardError => e
        # The file stays put. Every row carries its own uid and production
        # rejects a repeat, so the fix is to run this again once the reason for
        # the failure is gone.
        puts "\e[31mSync failed: #{e.class}: #{e.message}\e[0m"
        abort "Left #{waiting.length} calls in #{Buddy::UsageSpool.path}."
      end
    )

    puts "Synced #{result[:created]} calls (#{result[:duplicate]} already there, #{result[:skipped]} skipped)."
    if result[:skipped].to_i.positive?
      puts "\e[33m#{result[:skipped]} rows were not recorded — the lines are still in #{result[:archived]}\e[0m"
    end
    puts "Archived to #{result[:archived]}."
  end

  desc "Spool the local Buddy usage rows this database already holds, but has never sent"
  task :usage_backfill, [:days] => :environment do |_t, args|
    abort "Production writes its own usage rows — nothing to backfill." if Rails.env.production?

    rows = Buddy::UsageSync.backfill!(days: args[:days])
    if rows.empty?
      # Only rows stamped `development` are candidates. A development database
      # restored from a production backup is mostly production's rows, and they
      # are already counted there.
      puts "Nothing to add — every local row is already spooled or synced."
      next
    end

    spend = rows.sum(&:cost_micros)
    puts "Spooled #{rows.length} calls (#{Buddy::GPT::Pricing.format_micros(spend)}). " \
         "Run `bx rails buddy:usage_sync` to hand them over."
  end
end
