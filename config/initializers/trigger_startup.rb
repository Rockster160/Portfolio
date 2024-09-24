::Jil::Executor.async_trigger(User.me, :startup, {
  merge: `git rev-parse HEAD`.strip,
  **(`git log --no-merges -n 1 --format="%H|%an|%s"`.strip.then { |raw|
    hash, author, message = raw.split("|")
    { hash: hash, author: author, message: message }
  })
})
