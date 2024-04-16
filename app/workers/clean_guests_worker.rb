class CleanGuestsWorker
  include Sidekiq::Worker

  def perform
    associations = User.reflections.symbolize_keys.except(:push_sub)
    missing = associations.each_with_object({}) do |(association_name, reflection), obj|
      next if reflection.options.keys.include?(:through)

      obj[reflection.table_name.to_sym] = { id: nil }
    end

    User.guest
      .where(created_at: ..1.week.ago)
      .left_outer_joins(associations.keys)
      .where(missing)
      .destroy_all
  end

end
