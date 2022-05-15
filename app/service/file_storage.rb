module FileStorage
  module_function

  CREDENTIALS = Aws::Credentials.new(ENV["PORTFOLIO_S3_ACCESS_KEY"], ENV["PORTFOLIO_S3_SECRET_KEY"])
  DEFAULT_REGION = "us-east-1"
  DEFAULT_BUCKET = "ardesian-storage"

  def upload(file_data, filename: nil, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    Aws::S3::Resource.new(region: region, credentials: CREDENTIALS)
      .bucket(bucket)
      .object(filename || "file-#{Time.current.strftime("%Y-%m-%d-%H-%M-%S")}")
      .put(body: file_data)
    filename
  end

  def download(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    Aws::S3::Resource.new(region: region, credentials: CREDENTIALS)
      .bucket(bucket)
      .object(filename)
      .get
      .body
      .read
  end

  # def delete(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
  #   Aws::S3::Resource.new(region: region, credentials: CREDENTIALS)
  #     .bucket(bucket)
  #     .object(filename)
  #     .delete
  # end

  def expiring_url(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    Aws::S3::Resource.new(region: region, credentials: CREDENTIALS)
      .bucket(bucket)
      .object(filename)
      .presigned_url(:get, expires_in: 1.hour.to_i)
  end
end
