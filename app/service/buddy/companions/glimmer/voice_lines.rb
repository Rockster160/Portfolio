# Glimmer's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s**, done. That's a small light on.", mood: :content
  say "Oh, **%<name>s**. Well done, friend.", mood: :loving
  say "**%<name>s** finished. One thing lighter.", mood: :happy
  say "That's **%<name>s** settled. Good.", mood: :content
  say "**%<name>s**. You kept going, and it's done.", mood: :loving
  say "Oh lovely - **%<name>s** off the list.", mood: :star
  say "**%<name>s** done. Take the small win.", mood: :grin
  say "There. **%<name>s**, finished and quiet.", mood: :content
  say "**%<name>s**. That was yours to do, and you did it.", mood: :loving
  say "One more done. **%<name>s**.", mood: :star
end

lines :wake_yawn do
  say "*yaaawn* Oh - you're here.", mood: :surprised
  say "Mm. My light was low. Hello, friend.", mood: :content
  say "*flickers back on* There we are.", mood: :happy
  say "Oh, hello. I was drifting.", mood: :loving
  say "Back now. Give me a moment to brighten.", mood: :content
end

lines :routine_run do
  say "Easing into **%<name>s**.", mood: :content
  say "Lighting up **%<name>s** for you.", mood: :happy
  say "Here we go. **%<name>s**, one thing at a time.", mood: :grin
  say "Settling **%<name>s** into place.", mood: :loving
  say "Oh, **%<name>s**. Let's begin.", mood: :star
  say "**%<name>s**, gently now.", mood: :content
  say "Starting **%<name>s**. I've got this part.", mood: :happy
  say "Of course, friend. **%<name>s**.", mood: :loving
  say "**%<name>s** it is. Here we go.", mood: :grin
  say "Bringing **%<name>s** to life.", mood: :star
end

lines :routine_empty do
  say "Though nothing in it lit up. What it reaches for may have moved.", mood: :sad
  say "It came back empty, friend. Something it points at is gone.", mood: :surprised
  say "None of it would go, though. I think what it's pointing at has moved on.", mood: :sad
  say "Oh. Nothing in it found what it was reaching for.", mood: :surprised
end

lines :greeting_morning do
  say "Good morning!", mood: :content
  say "Morning, friend!", mood: :loving
  say "Hi there!", mood: :happy
  say "Morning!", mood: :grin
end

lines :greeting_afternoon do
  say "Good afternoon!", mood: :content
  say "Hi, friend!", mood: :loving
  say "Afternoon!", mood: :happy
  say "Hello there!", mood: :grin
end

lines :greeting_evening do
  say "Good evening!", mood: :content
  say "Evening, friend!", mood: :loving
  say "Hi there!", mood: :happy
  say "Evening!", mood: :grin
end

lines :greeting_late_night do
  say "Hi there!", mood: :happy
  say "Hello, friend!", mood: :loving
  say "Hey there!", mood: :content
  say "Hello!", mood: :grin
end
