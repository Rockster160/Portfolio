class RemoveUnusedIndexes < ActiveRecord::Migration[7.0]
  def change
    remove_index :log_trackers, name: "index_log_trackers_on_location_id"
    remove_index :command_proposal_iterations, name: "index_command_proposal_iterations_on_requester_id"
    remove_index :command_proposal_iterations, name: "index_command_proposal_iterations_on_approver_id"
    remove_index :user_survey_responses, name: "index_user_survey_responses_on_survey_id"
    remove_index :user_survey_responses, name: "index_user_survey_responses_on_survey_question_id"
    remove_index :survey_question_answer_results, name: "index_survey_question_answer_results_on_survey_id"
    remove_index :survey_question_answer_results, name: "index_survey_question_answer_results_on_survey_question_id"
    remove_index :survey_question_answer_results, name: "index_survey_question_answer_results_on_survey_result_id"
    remove_index :survey_question_answers, name: "index_survey_question_answers_on_survey_id"
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_on_blob_id"
    remove_index :command_proposal_comments, name: "index_command_proposal_comments_on_author_id"
    remove_index :pghero_query_stats, name: "index_pghero_query_stats_on_database_and_captured_at"
    remove_index :recipe_favorites, name: "index_recipe_favorites_on_recipe_id"
    remove_index :recipe_shares, name: "index_recipe_shares_on_recipe_id"
  end
end
