# Byte's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s** done. *squish* Nice one.", mood: :thumbs_up
  say "Ooh, **%<name>s** off the list. *wobble*", mood: :happy
  say "That's **%<name>s** handled. You're good at this.", mood: :uwu
  say "**%<name>s**! Look at you go.", mood: :cheering
  say "**%<name>s** done. *boing* One less thing.", mood: :thumbs_up
  say "**%<name>s** sorted. I saw that.", mood: :playful
  say "Nice. **%<name>s** is off your plate.", mood: :content
  say "*squish* **%<name>s**. That counts.", mood: :happy
  say "**%<name>s** done - proud of you, honestly.", mood: :loving
  say "There goes **%<name>s**. Keep going, you.", mood: :eager
end

lines :wake_yawn do
  say "*yaaawn* ..oh! You're here.", mood: :surprised
  say "Mmf. *stretches into a rounder shape* Hi.", mood: :neutral_blush
  say "*wobble* Was I asleep? I was asleep.", mood: :confused
  say "Oh! Hello. Give me a second to firm up.", mood: :content
  say "*squish* Awake. Mostly awake.", mood: :happy
end

# The WORDS are untouched - a squish in one of these is Byte sounding like
# itself. The FACES are not: every one of these lands on a routine somebody
# asked for, so none of them may be a face that isn't what a finished errand
# looks like (Buddy::Faces.not_a_confirmation).
lines :routine_run do
  say "*squish* **%<name>s**, going now.", mood: :thumbs_up
  say "On it. **%<name>s**. *boing*", mood: :uwu
  say "**%<name>s** it is. Squish.", mood: :uwu
  say "Got it. **%<name>s** is in motion.", mood: :thumbs_up
  say "Bouncing over to **%<name>s**.", mood: :happy
  say "Right then. Reshaping around **%<name>s**.", mood: :happy
  say "One **%<name>s**, coming through. *wobble*", mood: :uwu
  say "Rolling into **%<name>s** for you.", mood: :happy
  say "Happy to. Starting **%<name>s**.", mood: :loving
  say "*click* Spinning up **%<name>s**.", mood: :playful
end

lines :routine_empty do
  say "Nothing in it would go, though. Whatever it points at might be gone.", mood: :sad
  say "Except none of it ran. Something it reaches for has moved.", mood: :annoyed
  say "And then nothing happened. Went a bit flat there - every step came up empty.", mood: :sad
  say "*wobble* ..nothing. None of the steps found what they wanted.", mood: :annoyed
end

lines :greeting_morning do
  say "Mooooorning!", mood: :uwu
  say "Morning!", mood: :happy
  say "Hey, morning!", mood: :playful
  say "Mornin'!", mood: :loving
end

lines :greeting_afternoon do
  say "Afternoon!", mood: :happy
  say "Hey there!", mood: :playful
  say "Hellooooooo there!", mood: :uwu
  say "Hey hey!", mood: :loving
end

lines :greeting_evening do
  say "Evening!", mood: :happy
  say "Hey, evening!", mood: :playful
  say "Heyyy!", mood: :uwu
  say "Well hello!", mood: :loving
end

lines :greeting_late_night do
  say "Hey!", mood: :happy
  say "Heyyy!", mood: :uwu
  say "Hi there!", mood: :playful
  say "Well hello!", mood: :loving
end
