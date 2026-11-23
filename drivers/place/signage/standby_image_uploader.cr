require "placeos-driver"
require "placeos-driver/interface/standby_image"
require "place_calendar"

class Place::ImageUploader < PlaceOS::Driver
  descriptive_name "Image Uploader"
  generic_name :ImageUploader
  description %(takes images from digitial signage playlists and applies them as standby images.
    In joinable rooms, where the system contains the remote rooms receivers, configure a
    `local_decoders` system or zone setting listing the rooms receivers i.e. ["Decoder_1", "Decoder_2"])

  accessor location_services : LocationServices_1
  accessor staff_api : StaffAPI_1

  default_settings({
    signage_sync_cron: "0 2 * * *",
    apply_exactly:     false,
  })

  def get_all_systems_in_building : Array(String)
    # returns a hash of level zones mapped to system IDs, which we flatten into an array of system IDs.
    location_services.get_systems_list.get.as_h.values.flat_map(&.as_a).map(&.as_s)
  end

  @apply_exactly : Bool = false
  @sync_lock = Mutex.new
  @sync_task : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

  def on_update
    @apply_exactly = setting?(Bool, :apply_exactly) || false

    @sync_task.try &.cancel
    @sync_task = nil
    signage_sync_cron = setting?(String, :signage_sync_cron)
    return unless signage_sync_cron

    timezone = config.control_system.try(&.timezone).presence
    location = timezone ? Time::Location.load(timezone) : Time::Location.local

    # Push Images on this schedule
    @sync_task = schedule.cron(signage_sync_cron, timezone: location) do
      manual_update
    end
  end

  getter last_checked : Int64? = nil

  def manual_update(modified_since : Int64? = nil)
    @sync_lock.synchronize do
      started_at = Time.utc.to_unix
      get_all_systems_in_building.uniq.each do |system_id|
        sync_room(system_id, modified_since)
      rescue error
        logger.warn(exception: error) { "unable to sync standby images for #{system_id}" }
      end
      @last_checked = started_at
    end
  end

  private def sync_room(system_id : String, modified_since : Int64?)
    status_key = "background_images/#{system_id}"
    previous = status?(Hash(String, String), status_key)
    verified = previous || {} of String => String

    # With no delivery history, an explicit last-modified check can tell us
    # whether a healthy device is already current. Always get the effective
    # playlist to determine which receivers to reconcile and what to retry.
    playlist = staff_api.signage_playlist(system_id, nil).get.as_a
    unchanged = false
    if modified_since && !previous
      if latest = staff_api.signage_playlist(system_id, modified_since).get.as_a?
        playlist = latest
      else
        unchanged = true
      end
    end
    images = playlist.select { |item| item["media_type"].as_s.downcase == "image" }
    if images.empty?
      self[status_key] = {} of String => String
      return
    end

    receivers = system(system_id).implementing(Interface::StandbyImage).to_a
    if local = local_decoders(system_id)
      receivers.select! { |receiver| local.includes?("#{receiver.module_name}_#{receiver.index}") }
    end
    receivers = receivers.first(images.size) if @apply_exactly
    targets = receivers.map(&.module_id).to_set
    verified.select! { |id, _| targets.includes?(id) }
    self[status_key] = verified

    receivers.each_with_index do |receiver, index|
      item = images[index % images.size]
      upload_id = item["media_id"].as_s
      revision = {upload_id, item["updated_at"]?}.to_json
      # StandbyImage requires the setter. Only drivers advertising read-back
      # can establish current device state without a recorded delivery.
      supports_readback = receiver.__metadata__.interface.has_key?("background_image_ready?")
      known_current = verified[receiver.module_id]? == revision || (unchanged && supports_readback)
      if !known_current || (supports_readback && !receiver.background_image_ready?.get.as_bool)
        if verified.delete(receiver.module_id)
          self[status_key] = verified
        end
        direct_url = URI.parse(staff_api.upload_content_url(upload_id).get.as_s)
        extension = File.extname(direct_url.path).lchop('.')
        url = staff_api.signage_download_url(upload_id, extension).get.as_s
        receiver.set_background_image(url).get
      end

      if verified[receiver.module_id]? != revision
        verified[receiver.module_id] = revision
        self[status_key] = verified
      end
    rescue error
      logger.warn { "standby image sync failed for #{receiver.module_name}_#{receiver.index} in #{system_id} (#{error.class})" }
    end
  end

  # the receivers that belong to the room (i.e. `Decoder_1`), configured using
  # the `local_decoders` system or zone setting. Joinable rooms need this as
  # their systems also contain the remote rooms receivers.
  # nil if not configured, all receivers in the system belong to the room.
  protected def local_decoders(system_id : String) : Array(String)?
    allow_list = staff_api.system_settings(system_id, "local_decoders").get
    allow_list.as_a.map(&.as_s) unless allow_list.raw.nil?
  end
end
