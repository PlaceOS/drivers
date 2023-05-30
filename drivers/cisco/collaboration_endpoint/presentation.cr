require "placeos-driver/interface/switchable"
require "./xapi"

module Cisco::CollaborationEndpoint::Presentation
  enum PresentationInputs
    None
    Input1
    Input2
    Input3
    Input4
  end

  include PlaceOS::Driver::Interface::InputSelection(PresentationInputs)
  include Cisco::CollaborationEndpoint::XAPI

  enum SendingMode
    LocalRemote
    LocalOnly
  end

  @sending_mode : SendingMode = SendingMode::LocalRemote
  @presenting_input : Int32? = nil

  command({"Presentation Start" => :presentation_start},
    presentation_source_: 1..2,
    sending_mode_: SendingMode,
    connector_id_: 1..2,
    instance_: 1..6) # TODO:: support "New"
  command({"Presentation Stop" => :presentation_stop},
    instance_: 1..6,
    presentation_source_: 1..4)

  # Provide compatabilty with the router module for activating presentation.
  def switch_to(input : PresentationInputs)
    if input.none?
      @presenting_input = nil
      presentation_stop
    else
      source = input.to_s[5..-1].to_i
      @presenting_input = source

      presentation_start(
        presentation_source: source,
        sending_mode: @sending_mode
      )
    end

    self[:presenting_input] = @presenting_input
  end

  def send_presentation_to(remote : Bool)
    @sending_mode = remote ? SendingMode::LocalRemote : SendingMode::LocalOnly
    self[:present_to_remote] = remote

    if input = @presenting_input
      presentation_start(
        presentation_source: input,
        sending_mode: @sending_mode
      )
    end
  end
end
