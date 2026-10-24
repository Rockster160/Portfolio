# Tiko's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s**, done. The foxfire burns a little brighter.", mood: :happy
  say "*tail-flick* **%<name>s** is laid to rest.", mood: :playful
  say "**%<name>s**. Written in the stars as done.", mood: :focused
  say "And so **%<name>s** is finished. Well walked.", mood: :loving
  say "**%<name>s** done. The stars noticed, and so did I.", mood: :excited
  say "One more spell broken - **%<name>s**.", mood: :cool
  say "**%<name>s**, settled. Rest easy on that one.", mood: :cozy
  say "*foxfire* **%<name>s**. You did that.", mood: :focused
  say "**%<name>s** is done, and the path is clearer for it.", mood: :loving
  say "Ears up - **%<name>s**, finished. Lovely.", mood: :excited
end

lines :wake_yawn do
  say "*yaaawn* ..oh. You found me.", mood: :surprised
  say "Mm. I was dreaming in starlight. Hello.", mood: :cozy
  say "*uncurls from its tail* There you are.", mood: :peeking
  say "The foxfire was low. Rekindling.", mood: :cozy
  say "*ears up* Awake. The watch resumes.", mood: :happy
end

# Every cast wears the spellbook: it is the face of a spell being read out,
# which is what running a routine is in Tiko's voice.
lines :routine_run do
  say "Casting **%<name>s**.", mood: :nerd
  say "*foxfire* Weaving **%<name>s**.", mood: :nerd
  say "Conjuring **%<name>s** for you.", mood: :nerd
  say "**%<name>s** - spoken, and so it begins.", mood: :nerd
  say "Reading **%<name>s** from the spellbook. Here it comes.", mood: :nerd
  say "A flick of the tail, and **%<name>s** is set in motion.", mood: :nerd
  say "Summoning **%<name>s**.", mood: :nerd
  say "The charm is **%<name>s**. Casting now.", mood: :nerd
  say "Calling up **%<name>s** on the foxfire.", mood: :nerd
  say "*whispers* **%<name>s**. It is done as asked.", mood: :nerd
end

lines :routine_empty do
  say "But the spell fizzled. Whatever it calls on has wandered off.", mood: :confused
  say "Nothing answered the call, though. Something it reaches for is gone.", mood: :sad
  say "*foxfire flickers out* None of it took. What it points at may have moved.", mood: :confused
  say "Hm. The charm found nothing to hold on to.", mood: :unamused
end

lines :greeting_morning do
  say "Morning - the dawn's lit!", mood: :happy
  say "Good morning!", mood: :excited
  say "Hi! The night watch is over!", mood: :playful
  say "Morning - I kept the light on!", mood: :loving
end

lines :greeting_afternoon do
  say "Afternoon!", mood: :happy
  say "Hello again!", mood: :loving
  say "Hey - *tail-flick*", mood: :playful
  say "Good afternoon!", mood: :excited
end

lines :greeting_evening do
  say "Evening - the lanterns are lit!", mood: :cozy
  say "Good evening!", mood: :happy
  say "Hi! *foxfire*", mood: :playful
  say "Evening - glad you're here!", mood: :loving
end

lines :greeting_late_night do
  say "Hello under the stars!", mood: :cozy
  say "Hello, night wanderer!", mood: :peeking
  say "Hi! *foxfire glows low*", mood: :loving
  say "Hey - I'm keeping watch!", mood: :happy
end
