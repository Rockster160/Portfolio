#!/bin/bash
# Fetch raw email contents from S3 by Email id (production data).
# Usage:
#   bash .claude/prod-emails.sh 51186 51183 51182
#   bash .claude/prod-emails.sh 51186,51183,51182
#
# For each id, prints a delimiter line then the raw RFC 822 message body.

set -e

if [ "$#" -eq 0 ]; then
  echo "Usage: bash .claude/prod-emails.sh <email_id> [<email_id> ...]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Normalize comma-/space-separated args into a comma-joined SQL id list.
IDS_CSV="$(echo "$*" | tr ' ,' '\n\n' | grep -E '^[0-9]+$' | paste -sd, -)"

if [ -z "$IDS_CSV" ]; then
  echo "No valid numeric email ids in: $*" >&2
  exit 1
fi

# Load S3 credentials from the app's .env (only the two we need).
PORTFOLIO_S3_ACCESS_KEY="$(grep -E '^PORTFOLIO_S3_ACCESS_KEY=' "$REPO_DIR/.env" | head -1 | cut -d= -f2-)"
PORTFOLIO_S3_SECRET_KEY="$(grep -E '^PORTFOLIO_S3_SECRET_KEY=' "$REPO_DIR/.env" | head -1 | cut -d= -f2-)"
export PORTFOLIO_S3_ACCESS_KEY PORTFOLIO_S3_SECRET_KEY

# Ask prod for (id, s3_key) pairs as CSV.
# active_storage_blobs.key is the object name inside the ardesian-emails bucket.
QUERY="COPY (SELECT e.id, b.key FROM emails e JOIN active_storage_attachments a ON a.record_type = 'Email' AND a.record_id = e.id AND a.name = 'mail_blob' JOIN active_storage_blobs b ON b.id = a.blob_id WHERE e.id IN ($IDS_CSV) ORDER BY e.id) TO STDOUT WITH (FORMAT csv);"

MAPPING="$(bash "$SCRIPT_DIR/prod-query.sh" "$QUERY")"

if [ -z "$MAPPING" ]; then
  echo "No emails found for ids: $IDS_CSV" >&2
  exit 1
fi

cd "$REPO_DIR"
echo "$MAPPING" | PORTFOLIO_S3_ACCESS_KEY="$PORTFOLIO_S3_ACCESS_KEY" \
  PORTFOLIO_S3_SECRET_KEY="$PORTFOLIO_S3_SECRET_KEY" \
  bundle exec ruby -r aws-sdk-s3 -e '
    creds = Aws::Credentials.new(
      ENV.fetch("PORTFOLIO_S3_ACCESS_KEY"),
      ENV.fetch("PORTFOLIO_S3_SECRET_KEY"),
    )
    bucket = Aws::S3::Resource.new(region: "us-east-1", credentials: creds).bucket("ardesian-emails")

    STDIN.each_line do |line|
      id, key = line.chomp.split(",", 2)
      next if id.to_s.empty? || key.to_s.empty?

      puts "===== EMAIL #{id} (s3://ardesian-emails/#{key}) ====="
      begin
        puts bucket.object(key).get.body.read
      rescue Aws::S3::Errors::NoSuchKey
        puts "[missing in S3]"
      rescue => e
        puts "[error: #{e.class}: #{e.message}]"
      end
      puts
    end
  '
