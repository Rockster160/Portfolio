::CommandProposal.configure do |config|
  config.approval_required = false
  # Change if your base user class has a different model name
  config.user_class_name = "User"
  config.controller_var = :current_user

  # Scope for your user class that determines users who are permitted to interact with commands (highly recommended to make this very exclusive, as any users in this scope will be able to interact with your database directly)
  config.role_scope = :admin

  # Method called to display a user's name
  config.user_name = :username
end
