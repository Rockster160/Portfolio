# Where a HomeScreenIcon record's picked icon is served, or nil while it has
# none. Signed, since the browser fetches it without cookies, and stamped
# with updated_at, so a long cache never shows a stale icon.
module HomeScreenIconHelper
  def home_screen_icon_url(record)
    return unless record.icon?

    stamp = record.updated_at.to_i
    token = record.install_token
    case record
    when List then icon_list_path(record, key: token, v: stamp)
    when ListBuilder then icon_list_builder_path(record, t: token, v: stamp)
    when MealBuilder then icon_meal_builder_path(record, t: token, v: stamp)
    when QuestBoard then quest_board_icon_path(record, t: token, v: stamp)
    when TimerPage then timer_page_icon_path(slug: record.slug, t: token, v: stamp)
    end
  end
end
