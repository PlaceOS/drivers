require "placeos-driver"
require "placeos-driver/interface/switchable"
require "placeos-driver/interface/muteable"

# Documentation:
# * REST API: https://assets.prod.pim.lightware.com/assets/File-Downloads/Guides-and-Manuals/Application-Note/Lightware's_Rest_API_Environment_ApplicationNotes.pdf
# * LW3 tree (UCX): https://assets.prod.pim.lightware.com/assets/File-Downloads/Guides-and-Manuals/User-Manual/HTML/UCX_Series/UM.html
# * LW3 tree (MMX2): https://assets.prod.pim.lightware.com/assets/File-Downloads/Guides-and-Manuals/User-Manual/MMX2_series_UserManual.pdf
#
# The REST API maps the LW3 tree onto HTTP, `/V1/MEDIA/VIDEO/XP:switch` becomes
# `POST /api/V1/MEDIA/VIDEO/XP/switch` with a plain text body `I5:O1;I3:O2`.
# Input `0` disconnects an output.

class Lightware::Switcher < PlaceOS::Driver
  include Interface::Switchable(Int32 | String, Int32 | String)
  include Interface::Muteable

  generic_name :Switcher
  descriptive_name "Lightware Switcher (REST API)"
  description <<-DESC
    Lightware UCX / DCX / MMX2 switchers using the LW3 REST API.
    REST API basic authentication (username is fixed as `admin`) is optional,
    it can be enabled via the device web interface or by setting a password.
    Audio port numbering differs from video on these devices, so switching
    layer `All` only routes video. Set the audio output policy to
    `Follow video` on the device or switch the `Audio` layer explicitly.
  DESC

  uri_base "http://192.168.0.50"

  default_settings({
    basic_auth: {
      username: "admin",
      password: "",
    },

    # video port counts, used for polling signal presence and routes
    input_count:  4,
    output_count: 2,

    poll_every: 60,
  })

  @input_count : Int32 = 4
  @output_count : Int32 = 2

  # output => input prior to a mute (unroute)
  @muted_video = {} of Int32 => Int32
  @muted_audio = {} of Int32 => Int32

  def on_update
    @input_count = setting?(Int32, :input_count) || 4
    @output_count = setting?(Int32, :output_count) || 2
    poll_every = (setting?(Int32, :poll_every) || 60).seconds

    schedule.clear
    schedule.every(poll_every) { query_status }
  end

  # ======================
  # Switchable interface
  # ======================

  def switch_to(input : Int32 | String)
    input = port_number(input)
    switch({input => (1..@output_count).to_a.map(&.as(Int32 | String))}, SwitchLayer::Video)
  end

  def switch(map : Hash(Int32 | String, Array(Int32 | String)), layer : SwitchLayer? = nil)
    media = case layer
            in Nil, .all?, .video? then "VIDEO"
            in .audio?             then "AUDIO"
            in .data?, .data2?
              logger.debug { "layer #{layer} not available on lightware switcher" }
              return
            end

    ties = map.flat_map do |input, outputs|
      inp = port_number(input)
      outputs.map { |output| {inp, port_number(output)} }
    end
    return if ties.empty?

    body = ties.join(";") { |(inp, outp)| inp.zero? ? "0:O#{outp}" : "I#{inp}:O#{outp}" }
    lw3_call("/V1/MEDIA/#{media}/XP/switch", body)

    ties.each { |(inp, outp)| update_route(media.downcase, outp, inp) }
    ties
  end

  # ======================
  # Muteable interface
  # (mute unroutes the output, unmute restores the previous route)
  # ======================

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    output = port_number(index)
    outputs = output.zero? ? (1..@output_count).to_a : [output]

    # audio ports are numbered independently, so AudioVideo acts on video
    switch_layer = layer.audio? ? SwitchLayer::Audio : SwitchLayer::Video
    key = layer.audio? ? "audio" : "video"
    muted = layer.audio? ? @muted_audio : @muted_video

    if state
      previous = outputs.map do |outp|
        current = self["#{key}#{outp}"]?.try(&.as_i?) || 0
        {outp, current}
      end

      switch({0.as(Int32 | String) => outputs.map(&.as(Int32 | String))}, switch_layer)
      previous.each { |(outp, inp)| muted[outp] = inp unless inp.zero? }
    else
      restore = Hash(Int32 | String, Array(Int32 | String)).new { |hash, inp| hash[inp] = [] of Int32 | String }
      outputs.each do |outp|
        if inp = muted[outp]?
          restore[inp] << outp
        end
      end
      # outputs without a remembered route remain unrouted (muted)
      switch(restore, switch_layer) unless restore.empty?
    end
  end

  # ======================
  # Status
  # ======================

  def query_status
    (1..@input_count).each { |input| signal_present?(input) }
    (1..@output_count).each { |output| connected_source?(output) }
  end

  # queries `/V1/MEDIA/VIDEO/I1.SignalPresent`
  def signal_present?(input : Int32) : Bool?
    value = lw3_get("/V1/MEDIA/VIDEO/I#{input}/SignalPresent")
    self["input_#{input}_sync"] = value.downcase == "true"
  rescue error
    logger.debug(exception: error) { "failed to query signal presence of I#{input}" }
    nil
  end

  # queries `/V1/MEDIA/VIDEO/XP/O1.ConnectedSource`, `0` indicates disconnected
  def connected_source?(output : Int32, layer : SwitchLayer = SwitchLayer::Video) : Int32?
    media = layer.audio? ? "AUDIO" : "VIDEO"
    input = port_number lw3_get("/V1/MEDIA/#{media}/XP/O#{output}/ConnectedSource")
    update_route(media.downcase, output, input)
  rescue error
    logger.debug(exception: error) { "failed to query #{media} source of O#{output}" }
    nil
  end

  # ======================
  # Helpers
  # ======================

  # an output is muted whenever it is unrouted (input 0), any route clears
  # the remembered pre-mute input as the output is no longer muted
  protected def update_route(key : String, output : Int32, input : Int32) : Int32
    (key == "audio" ? @muted_audio : @muted_video).delete(output) unless input.zero?
    self["#{key}#{output}_muted"] = input.zero?
    self["#{key}#{output}"] = input
  end

  # converts `I2`, `O2`, `"I2"` or `2` into a port number, anything else is 0 (disconnected)
  protected def port_number(port : Int32 | String) : Int32
    return port if port.is_a?(Int32)
    port.strip.strip('"').lchop('I').lchop('i').lchop('O').lchop('o').to_i? || 0
  end

  protected def lw3_get(path : String) : String
    response = get("/api#{path}")
    raise "GET #{path} failed with #{response.status_code}: #{response.body}" unless response.success?
    response.body.strip
  end

  protected def lw3_call(path : String, body : String = "") : String
    response = post("/api#{path}", body: body, headers: HTTP::Headers{
      "Content-Type" => "text/plain",
    })
    raise "POST #{path} (#{body}) failed with #{response.status_code}: #{response.body}" unless response.success?
    response.body.strip
  end
end
