class AddSurveyScoreType < ActiveRecord::Migration[7.0]
  def change
    add_column :surveys, :score_type, :integer, default: 0
    change_column_default :survey_questions, :format, from: nil, to: 0
  end
end
