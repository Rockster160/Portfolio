namespace :deploy do
  desc "Write git commit info to a JSON file"
  task :write_git_info do
    on roles(:app) do
      within release_path do
        # Get the current commit hash (HEAD)
        merge = capture(:git, "rev-parse HEAD").strip

        # Get the latest non-merge commit details
        git_log_raw = capture(:git, 'log --no-merges -n 1 --format="%H|%an|%s"').strip
        hash, author, message = git_log_raw.split("|")

        # Prepare the JSON content
        json_content = {
          merge: merge,
          hash: hash,
          author: author,
          message: message
        }.to_json

        # Write the JSON content to the file
        execute :echo, "'#{json_content}' > #{release_path}/config/git_info.json"
      end
    end
  end
end

after "deploy:updated", "deploy:write_git_info"
