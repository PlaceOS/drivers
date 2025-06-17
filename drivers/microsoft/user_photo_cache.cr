require "placeos-driver"
require "place_calendar"
require "digest/md5"
require "set"

# Downloads photos from MS Azure users for caching locally
# as fetching photos counts as an API request and hence
# require cachine to prevent API limits being reached
class Microsoft::UserPhotoCache < PlaceOS::Driver
  descriptive_name "Azure User Photo Cache"
  generic_name :AzureUserPhotoCache

  default_settings({
    # optional if only a subset of users are needed
    _user_group_id: "building@org.com",
    sync_cron:      "0 21 * * *",

    # supported sizes: 48, 64, 96, 120, 240, 360, 432, 504, 648
    photo_pixel_width: 96,
  })

  accessor directory : Calendar_1
  accessor staff_api : StaffAPI_1

  @time_zone : Time::Location = Time::Location.load("GMT")

  @syncing : Bool = false
  @sync_mutex : Mutex = Mutex.new
  @user_group_id : String? = nil

  getter pixel_width : Int32 = 96

  def on_update
    @time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(@time_zone_string)
    @sync_cron = setting?(String, :sync_cron).presence || "0 21 * * *"
    @user_group_id = setting?(String, :user_group_id)
    @graph_group_id = nil

    @pixel_width = setting?(Int32, :photo_pixel_width) || 96

    schedule.clear
    schedule.cron(@sync_cron, @time_zone) { perform_photo_sync }
  end

  getter graph_group_id : String do
    if user_group_id = @user_group_id.presence
      if user_group_id.includes?('@')
        directory.get_group(user_group_id).get["id"].as_s
      else
        user_group_id
      end
    else
      "all-users"
    end
  end

  getter time_zone_string : String = "GMT"
  getter sync_cron : String = "0 21 * * *"

  # extend with our next_page solution
  class ::PlaceCalendar::Member
    property next_page : String? = nil
  end

  alias DirUser = ::PlaceCalendar::Member

  def perform_photo_sync
    return "already syncing" if @syncing

    @sync_mutex.synchronize do
      begin
        @syncing = true
        sync_photos
      ensure
        @syncing = false
      end
    end
  end

  protected def get_members(next_page = nil)
    if @user_group_id.presence
      Array(DirUser).from_json directory.get_members(graph_group_id, next_page).get.to_json
    else
      Array(DirUser).from_json directory.list_users(next_page: next_page).get.to_json
    end
  end

  protected def sync_photos
    photos_checked = 0
    updated_photos = 0
    errors = 0

    # get the list of users in the active directory (page by page)
    # and sync the photos
    users = get_members
    loop do
      users.each do |user|
        next if user.suspended

        begin
          user_email = user.email.strip.downcase
          user.email = user_email
          username = user.username.strip.downcase
          user.username = username

          tags = if user_email == username
                   ["user-photo", user_email]
                 else
                   ["user-photo", user_email, username]
                 end

          logger.debug { "checking: #{tags}" }

          # check if there is an existing photo for the user
          uploads = staff_api.uploads(tags: tags).get
          updated_photos += 1 if compare_and_sync(uploads.as_a, tags)
          photos_checked += 1
        rescue error
          errors += 1
          logger.error(exception: error) { "failed to sync photo for #{user_email}" }
        end
      end

      next_page = users.first?.try(&.next_page)
      break unless next_page

      # ensure we don't blow any request limits
      logger.debug { "fetching next page..." }
      sleep 500.milliseconds
      users = get_members(next_page)
    end

    result = {
      photos_checked: photos_checked,
      updated_photos: updated_photos,
      errors:         errors,
    }
    @last_result = result
    self[:last_result] = result
    logger.info { "user photo sync results: #{result}" }
    result
  end

  getter last_result : NamedTuple(
    photos_checked: Int32,
    updated_photos: Int32,
    errors: Int32,
  )? = nil

  def sync_user(email : String)
    user = DirUser.from_json directory.get_user(email).get.to_json
    raise "user is suspended" if user.suspended

    user_email = user.email.strip.downcase
    user.email = user_email
    username = user.username.strip.downcase
    user.username = username

    tags = if user_email == username
             ["user-photo", user_email]
           else
             ["user-photo", user_email, username]
           end

    # check if there is an existing photo for the user
    uploads = staff_api.uploads(tags: tags).get
    compare_and_sync(uploads.as_a, tags)
  end

  protected def compare_and_sync(uploads : Array(JSON::Any), tags : Array(String)) : Bool
    graph_user = tags.last

    if uploads.empty?
      logger.debug { "  - no cached photo" }
      return save(tags, download(graph_user))
    end

    # remove any old photos one we've grabbed the current photo
    current_photo = uploads.shift

    logger.debug { "  - removing #{uploads.size} old photos" } unless uploads.empty?
    uploads.each { |upload| delete(upload) }

    # update the photo if there is no etag match
    if data = download(graph_user, current_photo["cache_etag"]?.try(&.as_s))
      result = save(tags, data)
      delete current_photo
      return result
    end
    false
  end

  record Download, payload : Bytes, etag : String? = nil, last_modified : Time? = nil

  protected def download(graph_user : String, etag : String? = nil) : Download?
    path = "https://graph.microsoft.com/v1.0/users/#{graph_user}/photos/#{pixel_width}x#{pixel_width}/$value"
    headers = HTTP::Headers.new
    headers["If-None-Match"] = etag if etag

    # this is always just a generic token on graph api
    access_token = directory.access_token(graph_user).get["token"].as_s
    headers["Authorization"] = "Bearer #{access_token}"

    # make the request
    response = HTTP::Client.get(path, headers: headers)
    if response.success? && (bytes = response.body.try(&.to_slice))
      logger.debug { "  - downloaded photo: #{bytes.size} bytes" }

      headers = response.headers
      last_modified = headers["Last-Modified"]?
      time = Time.parse_utc(last_modified, "%a, %d %b %Y %H:%M:%S GMT") if last_modified
      return Download.new(bytes, headers["ETag"]?, time)
    end

    raise "photo data request failed with #{response.status}\n#{response.body}" unless {404, 304}.includes?(response.status_code)
    logger.debug { "  - user doesn't have a photo, skipping..." }
    nil
  end

  protected def save(tags : Array(String), download : Download?) : Bool
    # no image uploaded to azure
    return false unless download

    logger.debug { "  - uploading image..." }

    # get the signed URL from PlaceOS
    user_org = tags.last.sub('@', '-')
    signed_url = staff_api.upload(
      file_name: "#{(download.last_modified || Time.utc).to_unix}-#{user_org}.jpg",
      file_size: download.payload.size,
      file_md5: Digest::MD5.base64digest(download.payload),
      file_mime: "image/jpeg",
      tags: tags,
      cache_etag: download.etag,
      cache_modified: download.last_modified,
    ).get

    sig = signed_url["signature"]
    verb = sig["verb"].as_s
    url = sig["url"].as_s
    headers_hash = sig["headers"].as_h.transform_values(&.as_s)

    headers = HTTP::Headers.new
    headers_hash.each do |key, value|
      headers[key] = value
    end

    # upload the image to our cache (S3 / Azure)
    response = HTTP::Client.exec verb, url, headers, download.payload
    raise "failed to upload image with #{response.status_code}\n#{response.body}\n#{signed_url}" unless response.success?
    true
  end

  protected def delete(upload : JSON::Any)
    # we're not calling get here as not too worried if this succeeds
    staff_api.upload_remove(upload["id"])
  rescue error
    logger.warn(exception: error) { "failed to delete old upload: #{upload["id"]}" }
  end
end
