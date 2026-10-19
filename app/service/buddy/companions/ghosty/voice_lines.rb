# Ghosty's own lines, for the things the system says in its voice with no
# model turn behind them. Each kind and its placeholders are described in
# Buddy::VoiceLines; a kind left out here falls back to Byte's.

lines :chore_done do
  say "**%<name>s** done! Yayyy 💜", mood: :grin
  say "Ooh you did **%<name>s**! The house thanks you!", mood: :excited
  say "**%<name>s**, ticked off! Go you 😊", mood: :wink
  say "Yesss, **%<name>s** sorted!", mood: :happy
  say "Look at that - **%<name>s** done!", mood: :star
  say "**%<name>s**! That's one less thing 💜", mood: :loving
  say "Okiiie, **%<name>s** is handled!", mood: :playful
  say "Aww nice, **%<name>s** done! So cosy now!", mood: :content
  say "**%<name>s**! You're doing so well.", mood: :loving
  say "Done! **%<name>s** off the list 😊", mood: :happy
end

lines :wake_yawn do
  say "*yaaawn* Oh! Hi 💜", mood: :surprised
  say "Mmmf.. hello! Was I drifting off?", mood: :content
  say "Oh! You're here! Hiii.", mood: :grin
  say "*floats up* Okiiie, I'm up!", mood: :happy
  say "Sleepy.. but I'm here 😊", mood: :loving
end

lines :routine_run do
  say "Okiiie, **%<name>s** is going!", mood: :grin
  say "On it! **%<name>s**, starting now 💜", mood: :happy
  say "Yayyy, **%<name>s**!", mood: :star
  say "Got it! Floating over to **%<name>s**..", mood: :content
  say "**%<name>s** it is! Doing that now 😊", mood: :wink
  say "Sure thing! **%<name>s**, coming right up!", mood: :happy
  say "Ooh **%<name>s**, yes! Drifting off to do it!", mood: :playful
  say "Okayyy! **%<name>s**, off it goes..", mood: :content
  say "Of course! **%<name>s** for you 💜", mood: :loving
  say "**%<name>s**! Here we goooo!", mood: :excited
end

lines :routine_empty do
  say "Hmm, nothing in it would go though.. I think something it points at has moved!", mood: :surprised
  say "Awww, but none of it ran! Whatever it reaches for might be gone now..", mood: :sad
  say "Ohh no, none of the steps would go.. they want something that isn't there!", mood: :confused
  say "Oop, that came back empty! Nothing in it could find what it wanted..", mood: :dizzy
end

lines :greeting_morning do
  say "Morning!", mood: :happy
  say "Mooorning!", mood: :grin
  say "Good morning!", mood: :content
  say "Morning morning!", mood: :star
end

lines :greeting_afternoon do
  say "Hiii!", mood: :grin
  say "Afternoon!", mood: :happy
  say "Heyyy!", mood: :wink
  say "Hi hi!", mood: :content
end

lines :greeting_evening do
  say "Evening! Cosy night ahead??", mood: :happy
  say "Hiii!", mood: :grin
  say "Good evening!", mood: :content
  say "Heyyy!", mood: :wink
end

lines :greeting_late_night do
  say "Hiii!", mood: :grin
  say "Hey! Can't sleep?", mood: :happy
  say "Hi hi!", mood: :content
  say "Heyyy!", mood: :wink
end
