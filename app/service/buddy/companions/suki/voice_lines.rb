# Suki's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s**, done! Ja, lovely.", mood: :cheery
  say "Ooh, **%<name>s** finished! Good one.", mood: :happy
  say "**%<name>s** off the list - zip zip!", mood: :excited
  say "Ja! **%<name>s** sorted.", mood: :cheery
  say "You did **%<name>s**! Wunderbar.", mood: :excited
  say "**%<name>s** done. Here, have a well done.", mood: :offering
  say "Chop chop - and **%<name>s** is finished!", mood: :happy
  say "**%<name>s**! That's the way.", mood: :cheery
  say "Ja, nice work on **%<name>s**.", mood: :loving
  say "One **%<name>s**, done and dusted!", mood: :excited
end

lines :wake_yawn do
  say "*yaaawn* Oh! Ja, hello!", mood: :surprised
  say "Mmf.. awake! I am awake.", mood: :happy
  say "Oh, you're here! One moment.", mood: :cheery
  say "*stretches* Ja, ja. Ready.", mood: :excited
  say "Hello! I was having a little rest.", mood: :loving
end

lines :routine_run do
  say "Ja, **%<name>s** coming right up!", mood: :cheery
  say "Off I go! **%<name>s**, chop chop!", mood: :excited
  say "**%<name>s** it is!!", mood: :happy
  say "Here you go, **%<name>s** starting!", mood: :offering
  say "Zipping off to do **%<name>s**!", mood: :excited
  say "Lovely! **%<name>s**, on it now!", mood: :cheery
  say "Sure! **%<name>s**, right away!", mood: :happy
  say "One **%<name>s**, coming up!", mood: :offering
  say "Ja of course! **%<name>s**, doing it now!", mood: :loving
  say "**%<name>s**! Here we go!!", mood: :excited
end

lines :routine_empty do
  say "Ag shame, but none of it would run! Something it points at might be gone!", mood: :dizzy
  say "Except nothing came of it! I think what it reaches for has moved!", mood: :annoyed
  say "Oooh, that came up empty! None of the steps could find their thing!", mood: :dizzy
  say "Hmm, nothing doing! Whatever it's pointing at isn't there any more!", mood: :annoyed
end

lines :greeting_morning do
  say "Morning!!", mood: :cheery
  say "Mooorning!", mood: :excited
  say "Howzit!", mood: :happy
  say "Good morning!", mood: :loving
end

lines :greeting_afternoon do
  say "Afternoon!", mood: :cheery
  say "Howzit!", mood: :happy
  say "Hiii!", mood: :excited
  say "Hey hey!", mood: :loving
end

lines :greeting_evening do
  say "Evening!", mood: :cheery
  say "Howzit!", mood: :happy
  say "Hiii!", mood: :excited
  say "Good evening!", mood: :loving
end

lines :greeting_late_night do
  say "Hiii!", mood: :excited
  say "Hey!", mood: :cheery
  say "Howzit!", mood: :happy
  say "Hey hey!", mood: :loving
end
