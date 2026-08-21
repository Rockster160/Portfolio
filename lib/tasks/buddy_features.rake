namespace :buddy do
  # Features are an allow-list, which means "why can't she do that?" is a real
  # question with a real answer. This prints it.
  #
  #   bx rails buddy:features            — everyone with a Buddy thread
  #   bx rails buddy:features[eve]       — one person
  desc "Show which Buddy features each person holds"
  task :features, [:username] => :environment do |_t, args|
    scope = User.where(id: ByteConversation.where(mode: :buddy).select(:user_id))
    scope = scope.by_username(args[:username]) if args[:username].present?
    people = scope.order(:id).to_a

    if people.empty?
      puts args[:username].present? ? "No Buddy user named #{args[:username]}." : "Nobody has a Buddy thread yet."
      next
    end

    features = Buddy::Features.all
    width    = features.map { |f| f.to_s.length }.max
    puts "core (timers, memory, reminders, undo, stash, routines, weather) is always on.\n\n"

    people.each { |user|
      held = Buddy::Features.enabled_for(user)
      puts "#{user.username} (##{user.id})"
      features.each { |feature|
        mark = held.include?(feature) ? "on " : "OFF"
        puts "  #{mark}  #{feature.to_s.ljust(width)}  #{Buddy::Features.label_for(feature)}"
      }
      tools = Buddy::Tools.function_schemas(user: user).length
      puts "  -> #{tools} of #{Buddy::Tools.all.length} tools offered\n\n"
    }
  end
end
