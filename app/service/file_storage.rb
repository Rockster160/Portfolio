module FileStorage
  module_function

  CREDENTIALS = Aws::Credentials.new(ENV["PORTFOLIO_S3_ACCESS_KEY"], ENV["PORTFOLIO_S3_SECRET_KEY"])
  DEFAULT_REGION = "us-east-1"
  DEFAULT_BUCKET = "ardesian-storage"

  def object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    Aws::S3::Resource.new(region: region, credentials: CREDENTIALS)
      .bucket(bucket)
      .object(filename)
  end

  def upload(file_data, filename: nil, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    filename = filename || "file-#{Time.current.strftime("%Y-%m-%d-%H-%M-%S")}"
    object(filename).tap { |f|
      f.put(body: file_data)
    }
  end

  def download(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
      .get
      .body
      .read
  end

  def soft_get(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    obj = object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)

    obj.get.body.read if obj.exists?
  end

  def delete(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
      .delete
  end

  def exists?(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
      .exists?
  end

  def expiring_url(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
      .presigned_url(:get, expires_in: 1.hour.to_i)
  end
end
