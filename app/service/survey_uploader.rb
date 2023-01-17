# SurveyName
#   Question1
#     Answer1
#       result: 1
#     Answer2
#       result: 2
#   Question2
#     Answer1
#       result: 1
#     Answer2
#       result: 2

# TODO: Only upload if doesn't exist already
# Dir["lib/assets/surveys/*"].each { |survey_path|
#   SurveyUploader.upload_by_lib(survey_path, rm_if_exists: false)
# }

# Also SurveyJsonUploader
class SurveyUploader
  def self.upload_by_lib(filepath, rm_if_exists: true)
    SurveyUploader.upload(File.read(filepath), rm_if_exists: rm_if_exists)
  end

  def self.upload(data, rm_if_exists: true)
    parsed = EasyYmlParser.parse(data) || {}
    survey_params = {
      description:       parsed.delete("description"),
      randomize_answers: parsed.delete("randomize"),
      score_type:        parsed.delete("type"),
    }.compact
    groups = parsed.delete("Groups")

    parsed.each do |survey_name, survey_data|
      return if !rm_if_exists && Survey.where(name: survey_name).any?

      survey = Survey.find_or_create_by(name: survey_name)
      survey.update(survey_params) if survey_params.any?

      survey.survey_question_answer_results.destroy_all # Should do updates instead?
      survey.survey_questions.destroy_all # Should do updates instead?
      survey.survey_results.destroy_all # Should do updates instead?

      groups&.each do |gname, gdetails|
        group = survey.survey_results.create(name: gname)
        next unless gdetails.present?

        group.survey_result_details.create(survey: survey, description: gdetails.gsub("\\n", "\n").gsub("\\t", "\t"))
      end

      survey_data&.each_with_index do |(sq_name, sq_data), sq_idx|
        sq = survey.survey_questions.create(text: sq_name, position: sq_idx)

        sq_data&.each_with_index do |(sqa_name, sqa_data), sqa_idx|
          sqa = sq.survey_question_answers.create(survey: survey, text: sqa_name, position: sqa_idx)

          sqa_data.each do |sqa_g, sqa_v|
            group = survey.survey_results.find_or_create_by(name: sqa_g)

            group.survey_question_answer_results.create(
              survey: survey,
              survey_question: sq,
              survey_question_answer: sqa,
              value: sqa_v
            )
          end
        end
      end
    end
  end
end
