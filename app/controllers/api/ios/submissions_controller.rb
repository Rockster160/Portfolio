class Api::Ios::SubmissionsController < Api::Ios::BaseController
  def show
    submission = current_user.app_device_submissions.find_by!(uuid: params[:id].to_s.downcase)
    render json: submission.serialize
  end

  def create
    raise ArgumentError, "an id is required" if params[:id].blank?
    unless AppDeviceSubmission::KINDS.map(&:to_s).include?(params[:kind].to_s)
      raise ArgumentError, "unknown kind #{params[:kind]}"
    end

    submission, duplicate = AppDevices::SubmissionProcessor.call(
      device: current_device,
      params: params.permit!.to_h.except(:controller, :action, :submission, :format),
    )
    render json: submission.serialize(duplicate: duplicate), status: duplicate ? :ok : :created
  end

  def blob_path(blob)
    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
  end

  # Photos go up first and the message carries their signed ids, the same
  # two steps the web composer takes.
  def uploads
    images = ByteImageIntake.call(params[:files])
    return render(json: { error: images.error }, status: :unprocessable_entity) unless images.ok?

    render json: {
      attachments: images.blobs.map { |blob|
        {
          signed_id:    blob.signed_id,
          filename:     blob.filename.to_s,
          content_type: blob.content_type,
          byte_size:    blob.byte_size,
          url:          absolute(blob_path(blob)),
        }
      },
    }, status: :created
  end
end
