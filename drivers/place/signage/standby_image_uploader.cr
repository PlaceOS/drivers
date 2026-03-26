require "placeos-driver"
require "placeos-driver/interface/standby_image"
require "place_calendar"

class Place::ImageUploader < PlaceOS::Driver
  descriptive_name "Image Uploader"
  generic_name :StaffAPI
  description %(helpers for requesting data held in the staff API.)

  accessor location_services : LocationServices_1
  accessor staff_api : StaffAPI_1

  default_settings({
    signage_sync_cron: "0 3 * * *",
  })

  def get_all_systems_in_building : Array(String)
    # returns a hash of level zones mapped to system IDs, which we flatten into an array of system IDs.
    location_services.get_systems_list.get.as_h.values.flat_map(&.as_a).map(&.as_s)
  end

  def on_update
    signage_sync_cron = setting?(String, :signage_sync_cron)
    return unless signage_sync_cron

    timezone = config.control_system.try(&.timezone).presence
    location = timezone ? Time::Location.load(timezone) : Time::Location.local

    # Push Images on this schedule
    schedule.cron(signage_sync_cron, timezone: location) do
      manual_update(last_checked)
      @last_checked = Time.utc.to_unix
    end
  end

  getter last_checked : Int64? = nil

  def manual_update(modified_since : Int64? = nil)
    get_all_systems_in_building.each do |system_id|
      # get the systems playlist
      playlist = staff_api.signage_playlist(system_id, modified_since).get.as_a?
      if playlist
        logger.debug { "applying #{playlist.size} images to #{system_id}" }
      else
        logger.debug { "skipping update to #{system_id} as no changes" }
        next
      end

      # apply the images to the displays in the system
      receivers = system(system_id).implementing(Interface::StandbyImage)
      logger.debug { "found #{receivers.size} devices to apply images" }

      receivers.each_with_index do |receiver, index|
        # select the item to be applied from the playlist
        item = index % playlist.size

        # get a crestron friendly URL
        url = staff_api.signage_download_url(playlist[item]["media_id"]).get.as_s
        logger.debug { "setting receiver#{index} to #{url}" }

        # apply it to the receiver
        receiver.set_background_image(url)
      end
    end
  end
end
