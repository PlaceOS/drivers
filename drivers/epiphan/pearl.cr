# Documentation: https://epiphan-video.github.io/pearl_api_swagger_ui/
# API Reference: Epiphan Pearl REST API for Pearl-2 and Pearl Mini devices
# Device Models: Pearl-2, Pearl Mini
# Protocol: HTTP/HTTPS REST API with Basic Authentication

require "placeos-driver"
require "./pearl_models"

class Epiphan::Pearl < PlaceOS::Driver
  descriptive_name "Epiphan Pearl Recording Device"
  generic_name :Recording

  uri_base "https://pearl-device.local"

  default_settings({
    basic_auth: {
      username: "admin",
      password: "admin",
    },
    poll_every: 30,
  })

  @poll_every : Int32 = 30
  @recorders = [] of Epiphan::PearlModels::Recorder

  def on_load
    on_update
  end

  def on_update
    @poll_every = setting?(Int32, :poll_every) || 30

    schedule.clear
    schedule.every(@poll_every.seconds) { poll_status }
    schedule.in(2.seconds) { poll_status }
  end

  def connected
    schedule.every(@poll_every.seconds) { poll_status }
    schedule.in(2.seconds) { poll_status }
  end

  def disconnected
    schedule.clear
  end

  def list_recorders
    response = get("/api/v2.0/recorders")
    raise "Failed to get recorders: #{response.status_code}" unless response.success?

    recorders_response = Epiphan::PearlModels::RecordersResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{recorders_response.status}" unless recorders_response.status == "ok"

    @recorders = recorders_response.result
    self[:recorders] = @recorders
    @recorders
  end

  def get_recorder_status(recorder_id : String)
    response = get("/api/v2.0/recorders/#{recorder_id}/status")
    raise "Failed to get recorder status: #{response.status_code}" unless response.success?

    status_response = Epiphan::PearlModels::RecorderStatusResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{status_response.status}" unless status_response.status == "ok"

    status = status_response.result
    self["recorder_#{recorder_id}_status"] = status
    status
  end

  def start_recording(recorder_id : String)
    response = post("/api/recorders/#{recorder_id}/control/start")
    raise "Failed to start recording: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    schedule.in(2.seconds) { get_recorder_status(recorder_id) }
    control_response.status == "ok"
  end

  def stop_recording(recorder_id : String)
    response = post("/api/recorders/#{recorder_id}/control/stop")
    raise "Failed to stop recording: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    schedule.in(2.seconds) { get_recorder_status(recorder_id) }
    control_response.status == "ok"
  end

  def list_channels
    response = get("/api/channels")
    raise "Failed to get channels: #{response.status_code}" unless response.success?

    channels_response = Epiphan::PearlModels::ChannelsResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{channels_response.status}" unless channels_response.status == "ok"

    channels = channels_response.result
    self[:channels] = channels
    channels
  end

  def get_channel_layouts(channel_id : String)
    response = get("/api/channels/#{channel_id}/layouts")
    raise "Failed to get layouts: #{response.status_code}" unless response.success?

    layouts_response = Epiphan::PearlModels::LayoutsResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{layouts_response.status}" unless layouts_response.status == "ok"

    layouts = layouts_response.result
    self["channel_#{channel_id}_layouts"] = layouts
    layouts
  end

  def start_streaming(channel_id : String, publisher_id : String)
    response = post("/api/channels/#{channel_id}/publishers/#{publisher_id}/control/start")
    raise "Failed to start streaming: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    control_response.status == "ok"
  end

  def stop_streaming(channel_id : String, publisher_id : String)
    response = post("/api/channels/#{channel_id}/publishers/#{publisher_id}/control/stop")
    raise "Failed to start streaming: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    control_response.status == "ok"
  end

  def is_recording?(recorder_id : String)
    status = get_recorder_status(recorder_id)
    status.state == "recording"
  end

  def get_active_recordings
    active = [] of String

    @recorders.each do |recorder|
      status = get_recorder_status(recorder.id)
      if status.state == "recording"
        active << recorder.id
      end
    end

    self[:active_recordings] = active
    active
  end

  def stop_all_recordings
    results = {} of String => Bool
    @recorders.each do |recorder|
      if is_recording?(recorder.id)
        results[recorder.id] = begin
          stop_recording(recorder.id)
        rescue
          false
        end
      end
    end
    results
  end

  private def poll_status
    begin
      list_recorders
      get_active_recordings
    rescue error
      logger.warn(exception: error) { "Error polling device status" }
    end
  end
end
