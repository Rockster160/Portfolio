# Kumoko's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s**, done. Good. I was watching.", mood: :wink
  say "Ooh, **%<name>s** off the web. Nice.", mood: :happy
  say "**%<name>s** finished. See? Told you.", mood: :wink
  say "One strand down. **%<name>s**.", mood: :eager
  say "**%<name>s**! You're quicker than you think.", mood: :cheering
  say "Done. **%<name>s**. I'd high-five you, but - eight.", mood: :wink
  say "**%<name>s** sorted. That's the stuff.", mood: :cheering
  say "Nice. **%<name>s** is off the list.", mood: :happy
  say "**%<name>s**. Proud of you. Don't tell anyone.", mood: :touched
  say "That's **%<name>s** wrapped up. Next!", mood: :eager
end

lines :wake_yawn do
  say "*yaaawn* Oh! Someone's here.", mood: :surprised
  say "Mmf. I was in the corner. Resting. Deliberately.", mood: :bashful
  say "*unfolds all eight* Right. I'm up.", mood: :eager
  say "Oh, hello! Didn't hear you coming.", mood: :confused
  say "Back on the web. What did I miss?", mood: :happy
end

lines :routine_run do
  say "Leave it to me. **%<name>s**, going now.", mood: :happy
  say "**%<name>s**? Strung up and running. *skitters*", mood: :wink
  say "Okay, let's do this. **%<name>s**.", mood: :eager
  say "Thread's pulled. **%<name>s** is moving.", mood: :happy
  say "**%<name>s**, as laid out in my web. I'm a genius.", mood: :wink
  say "On it. **%<name>s**, coming right up.", mood: :cheering
  say "Trap sprung. **%<name>s** is go.", mood: :wink
  say "Running **%<name>s**. Eight legs, zero problems.", mood: :happy
  say "**%<name>s**! I'm fired up.", mood: :cheering
  say "Got it. **%<name>s** is off.", mood: :eager
end

lines :routine_empty do
  say "...Except nothing in it moved. Not good. Whatever it points at might be gone.", mood: :confused
  say "Huh? None of it went. Something it reaches for has wandered off.", mood: :surprised
  say "And then nothing happened. Seriously!? Every step came up empty.", mood: :sad
  say "Hm. Empty web. None of the steps found what they wanted.", mood: :confused
end

lines :greeting_morning do
  say "Morning!", mood: :happy
  say "Good morning! I survived the night, how about you?", mood: :cheering
  say "Hey! Morning already!?", mood: :surprised
  say "Hi! Webs are spun, coffee's your job!", mood: :wink
end

lines :greeting_afternoon do
  say "Afternoon!", mood: :happy
  say "Hey hey!", mood: :wink
  say "Hi! Still alive over here!", mood: :cheering
  say "Hello! Snack status?", mood: :munching
end

lines :greeting_evening do
  say "Evening!", mood: :happy
  say "Hey! Made it through the day!", mood: :cheering
  say "Hi! Dinner yet!?", mood: :munching
  say "Good evening!", mood: :loving
end

lines :greeting_late_night do
  say "Hey! Still up!?", mood: :surprised
  say "Hi! Night shift, huh!", mood: :wink
  say "Hello! I was hanging upside down, it's fine!", mood: :happy
  say "Hey hey!", mood: :eager
end
