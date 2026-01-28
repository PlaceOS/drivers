# Documentation: https://epiphan-video.github.io/pearl_api_swagger_ui/
# API Reference: Epiphan Pearl REST API for Pearl-2 and Pearl Mini devices
# Device Models: Pearl-2, Pearl Mini
# Protocol: HTTP/HTTPS REST API with Basic Authentication

require "placeos-driver"
require "./pearl_models"

class Epiphan::Pearl < PlaceOS::Driver
  descriptive_name "Epiphan Pearl Recording Device"
  generic_name :Recording
  description <<-DESC
    Driver for Epiphan Pearl-2 and Pearl Mini recording/streaming devices.
    
    Requirements:
    - Pearl device must be accessible on the network
    - Admin credentials required for API access
    - REST API v2.0 must be enabled on the device
    
    Features:
    - Recording control (start/stop/pause/resume)
    - Streaming control for channels and publishers
    - Channel layout switching
    - Active recording/streaming monitoring
    - Publisher listing and status
    
    Based on Epiphan Pearl REST API v2.0
  DESC

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

  def on_update
    @poll_every = setting?(Int32, :poll_every) || 30

    schedule.clear
    schedule.every(@poll_every.seconds) { poll_status }
    schedule.in(2.seconds) { poll_status }
  end

  def connected
    schedule.every(@poll_every.seconds) { poll_status }
    schedule.in(2.seconds) {
      poll_status
      get_firmware
      get_connectivity_details
    }
  end

  def disconnected
    schedule.clear
  end

  def get_firmware
    response = get("/api/v2.0/system/firmware")

    raise "Failed to get firmware details: #{response.status_code}" unless response.success?

    firmware_response = Epiphan::PearlModels::FirmwareDetailsResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{firmware_response.status}" unless firmware_response.status == "ok"

    firmware = firmware_response.result
    self[:firmware] = firmware
    firmware
  end

  def get_connectivity_details
    response = get("/api/v2.0/system/connectivity/details")

    raise "Failed to get connectivity details: #{response.status_code}" unless response.success?

    connectivity_response = Epiphan::PearlModels::ConnectivityDetailsResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{connectivity_response.status}" unless connectivity_response.status == "ok"

    connectivity_details = connectivity_response.result
    self[:connectivity_details] = connectivity_details
    connectivity_details
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
    response = post("/api/v2.0/recorders/#{recorder_id}/control/start")
    raise "Failed to start recording: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    schedule.in(2.seconds) { get_recorder_status(recorder_id) }
    true
  end

  def stop_recording(recorder_id : String)
    response = post("/api/v2.0/recorders/#{recorder_id}/control/stop")
    raise "Failed to stop recording: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    schedule.in(2.seconds) { get_recorder_status(recorder_id) }
    true
  end

  def list_channels
    response = get("/api/v2.0/channels")
    raise "Failed to get channels: #{response.status_code}" unless response.success?

    channels_response = Epiphan::PearlModels::ChannelsResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{channels_response.status}" unless channels_response.status == "ok"

    channels = channels_response.result
    self[:channels] = channels
    channels
  end

  # Channel status endpoint not clearly defined in API spec - commenting out for now
  # def get_channel_status(channel_id : String)
  #   response = get("/api/v2.0/channels/#{channel_id}/status")
  #   raise "Failed to get channel status: #{response.status_code}" unless response.success?
  #
  #   status_response = Epiphan::PearlModels::ChannelStatusResponse.from_json(response.body.not_nil!)
  #   raise "API returned error: #{status_response.status}" unless status_response.status == "ok"
  #
  #   status = status_response.result
  #   self["channel_#{channel_id}_status"] = status
  #   status
  # end

  def get_channel_layouts(channel_id : String)
    response = get("/api/v2.0/channels/#{channel_id}/layouts")
    raise "Failed to get layouts: #{response.status_code}" unless response.success?

    layouts_response = Epiphan::PearlModels::LayoutsResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{layouts_response.status}" unless layouts_response.status == "ok"

    layouts = layouts_response.result
    self["channel_#{channel_id}_layouts"] = layouts
    layouts
  end

  def start_streaming(channel_id : String, publisher_id : String)
    response = post("/api/v2.0/channels/#{channel_id}/publishers/#{publisher_id}/control/start")
    raise "Failed to start streaming: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    true
  end

  def stop_streaming(channel_id : String, publisher_id : String)
    response = post("/api/v2.0/channels/#{channel_id}/publishers/#{publisher_id}/control/stop")
    raise "Failed to stop streaming: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    true
  end

  def is_recording?(recorder_id : String)
    status = get_recorder_status(recorder_id)
    status.state == Epiphan::PearlModels::RecorderState::Started
  end

  def get_active_recordings
    active = [] of String

    @recorders.each do |recorder|
      status = get_recorder_status(recorder.id)
      if status.state == Epiphan::PearlModels::RecorderState::Started
        active << recorder.id
      end
    end

    self[:number_of_active_recordings] = active.size
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

  def pause_recording(recorder_id : String)
    response = post("/api/v2.0/recorders/#{recorder_id}/control/pause")
    raise "Failed to pause recording: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    schedule.in(2.seconds) { get_recorder_status(recorder_id) }
    true
  end

  def resume_recording(recorder_id : String)
    response = post("/api/v2.0/recorders/#{recorder_id}/control/resume")
    raise "Failed to resume recording: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    schedule.in(2.seconds) { get_recorder_status(recorder_id) }
    true
  end

  def get_system_status
    response = get("/api/v2.0/system/status")
    raise "Failed to get system status: #{response.status_code}" unless response.success?

    status_response = Epiphan::PearlModels::SystemStatusResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{status_response.status}" unless status_response.status == "ok"

    status = status_response.result
    self[:system_status] = status
    status
  end

  def get_inputs_status
    response = get("/api/v2.0/inputs/status")
    raise "Failed to get inputs status: #{response.status_code}" unless response.success?

    status_response = Epiphan::PearlModels::InputStatusResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{status_response.status}" unless status_response.status == "ok"

    input_status = status_response.result
    status_response.result.each do |input|
      is_active = false
      if status = input.status
        if video = status.video
          is_active = (video.state == "active")
        end
      end
      self["#{input.id}_video_status"] = is_active
    end
    input_status
  end

  def list_publishers(channel_id : String)
    response = get("/api/v2.0/channels/#{channel_id}/publishers")
    raise "Failed to get publishers: #{response.status_code}" unless response.success?

    publishers_response = Epiphan::PearlModels::PublishersResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{publishers_response.status}" unless publishers_response.status == "ok"

    publishers = publishers_response.result
    self["channel_#{channel_id}_publishers"] = publishers
    publishers
  end

  def set_channel_layout(channel_id : String, layout_id : String)
    body = {
      layout_id: layout_id,
    }.to_json

    response = put("/api/v2.0/channels/#{channel_id}/set_layout", body: body, headers: {"Content-Type" => "application/json"})
    raise "Failed to set layout: #{response.status_code}" unless response.success?

    control_response = Epiphan::PearlModels::ControlResponse.from_json(response.body.not_nil!)
    raise "API returned error: #{control_response.status}" unless control_response.status == "ok"
    schedule.in(2.seconds) { get_channel_layouts(channel_id) }
    true
  end

  def get_active_streamings
    active = [] of NamedTuple(channel_id: String, publisher_ids: Array(String))

    channels = list_channels
    channels.each do |channel|
      active_publishers = [] of String
      publishers = list_publishers(channel.id)

      publishers.each do |publisher|
        # Check if this publisher is currently streaming
        if publisher.status && publisher.status.try &.state == Epiphan::PearlModels::StreamingState::Started
          active_publishers << publisher.id
        end
      end

      if !active_publishers.empty?
        active << {channel_id: channel.id, publisher_ids: active_publishers}
      end
    end

    self[:active_streamings] = active
    active
  end

  # Check if a channel has any active streaming publishers
  def is_streaming?(channel_id : String)
    publishers = list_publishers(channel_id)
    publishers.any? { |pub| pub.status && pub.status.try &.state == Epiphan::PearlModels::StreamingState::Started }
  end

  private def poll_status
    begin
      get_system_status
      get_inputs_status
      list_recorders
      get_active_recordings
      list_channels
      get_active_streamings if @recorders.size > 0
    rescue error
      logger.warn(exception: error) { "Error polling device status" }
    end
  end
end
