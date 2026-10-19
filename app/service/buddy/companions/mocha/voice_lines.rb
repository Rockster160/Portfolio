# Mocha's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s** done! Niiice one 💛", mood: :grin
  say "Ooh you did **%<name>s**! That's the way!", mood: :cheering
  say "**%<name>s**, ticked off! Go you ☕", mood: :wink
  say "Yesss, **%<name>s** sorted!", mood: :happy
  say "Look at that - **%<name>s** done!", mood: :cool
  say "**%<name>s**! That's the momentum going 😄", mood: :eager
  say "Okayyy, **%<name>s** is handled!", mood: :grin
  say "Aww nice, **%<name>s** done!", mood: :content
  say "**%<name>s**! You're on a roll.", mood: :loving
  say "Done! **%<name>s** off the list 😊", mood: :happy
end

lines :wake_yawn do
  say "*yaaawn* Oh! Hi 💛", mood: :surprised
  say "Mmmf.. hello! Give me a sec to warm up!", mood: :content
  say "Oh! You're here! Hiii.", mood: :grin
  say "*stretches* Okayyy, I'm up! What's first?", mood: :eager
  say "Sleepy.. but I'm here ☕", mood: :loving
end

lines :routine_run do
  say "On it! **%<name>s**, starting now 💛", mood: :happy
  say "Okayyy, **%<name>s** is going!", mood: :grin
  say "Let's gooo! **%<name>s**!", mood: :eager
  say "Got it! Setting **%<name>s** going..", mood: :content
  say "**%<name>s** it is! Doing that now 😊", mood: :wink
  say "Sure thing! **%<name>s**, coming right up!", mood: :happy
  say "Ooh **%<name>s**, yes! Brewing it!", mood: :grin
  say "Consider it handled! **%<name>s**, off it goes..", mood: :cool
  say "Of course! **%<name>s** for you 💛", mood: :loving
  say "**%<name>s**! Here we gooo!", mood: :cheering
end

lines :routine_empty do
  say "Hmm, nothing in it would go though.. I think something it points at has moved!", mood: :surprised
  say "Awww, but none of it ran! Whatever it reaches for might be gone now..", mood: :sad
  say "Ohh no, none of the steps would go.. they want something that isn't there!", mood: :queasy
  say "Oop, that came back empty! Nothing in it could find what it wanted..", mood: :dizzy
end

lines :greeting_morning do
  say "Mooorning!", mood: :grin
  say "Morning! Ready when you are ☕", mood: :happy
  say "Good morning!", mood: :content
  say "Morning morning! Let's make it a good one 😄", mood: :eager
end

lines :greeting_afternoon do
  say "Hiii!", mood: :grin
  say "Afternoon!", mood: :happy
  say "Heyyy!", mood: :wink
  say "Hi hi! How's it going??", mood: :content
end

lines :greeting_evening do
  say "Evening!", mood: :happy
  say "Hiii!", mood: :grin
  say "Good evening!", mood: :content
  say "Heyyy!", mood: :wink
end

lines :greeting_late_night do
  say "Hiii!", mood: :grin
  say "Hey! Still at it?", mood: :happy
  say "Hi hi!", mood: :content
  say "Heyyy!", mood: :wink
end
