require "placeos-driver/spec"

DriverSpecs.mock_driver "Echo360::DeviceCapture" do
  retval = exec(:system_status)
  expect_http_request do |request, response|
    if request.path == "/status/system"
      response.status_code = 200
      response << SYSTEM_STATUS
    else
      puts "unexpected path #{request.path}"
      response.status_code = 404
    end
  end
  retval.get

  status["api-versions"].should eq "3.0"

  retval = exec(:captures)
  expect_http_request do |_request, response|
    response.status_code = 200
    response << CAPTURE_STATUS
  end
  retval.get
  status[:captures].as_a.size.should eq(2)
end

CAPTURE_STATUS = <<-HEREDOC
        <captures>
            <capture version="1.0" id="0797b8dd-4c2d-415a-adf9-daf7f10e1759">
                <title>Underwater Basket Weaving 101 (UWBW-101-100) Spring 2014</title>
                <start-time>2014-02-12T15:30:00.000Z</start-time>
                <duration>3000</duration>
                <section ref="ec7a622a-da43-4a31-897f-841ea192f63d">Underwater Basket Weaving 101 (UWBW-101-100) Spring 2014</section>
                <capture-profile ref="74156b84-8edb-4016-a597-35abc0c1c486" />
                <presenters>
                    <presenter ref="9d56966e-3b39-4e26-b0f4-58bebc3ec4de">John Doe</presenter>
                </presenters>
                <device ref="00-1c-08-00-14-04" />
            </capture>
            <capture version="1.0" id="0797b8dd-4c2d-415a-adf9-daf7f10e1769">
                <title>Some other capture</title>
                <start-time>2014-02-13T15:30:00.000Z</start-time>
                <duration>1500</duration>
                <section ref="ec7a622a-da43-4a31-897f-841ea192f63e">Some other capture</section>
                <capture-profile ref="74156b84-8edb-4016-a597-35abc0c1c486" />
                <presenters>
                    <presenter ref="9d56966e-3b39-4e26-b0f4-58bebc3ec4df">Steve</presenter>
                </presenters>
                <device ref="00-1c-08-00-14-05" />
            </capture>
        </captures>
    HEREDOC

SYSTEM_STATUS = <<-HEREDOC
        <status>
        <wall-clock-time>2014-02-12T15:02:19.037Z</wall-clock-time>
        <api-versions>
        <api-version>3.0</api-version>
        </api-versions>
        <capture-profiles>
        <capture-profile>Audio Only (Podcast). Balanced between file size &#038; quality</capture-profile>
        <capture-profile>Display Only (Podcast/Vodcast/EchoPlayer). Balanced between file size &#038; quality</capture-profile>
        <capture-profile>Display/Video (Podcast/Vodcast/EchoPlayer). Balanced between file size &#038; quality</capture-profile>
        <capture-profile>Display/Video (Podcast/Vodcast/EchoPlayer). Optimized for quality/full motion video</capture-profile>
        <capture-profile>DualDisplay (Podcast/Vodcast/EchoPlayer). Optimized for file size &#038; bandwidth</capture-profile>
        <capture-profile>Dual Video (Podcast/Vodcast/EchoPlayer) -Balance between file size &#038; quality</capture-profile>
        <capture-profile>Dual Video (Podcast/Vodcast/EchoPlayer) -High Quality</capture-profile>
        <capture-profile>Video Only (Podcast/Vodcast/EchoPlayer). Balanced between file size &#038; quality</capture-profile>
        </capture-profiles>
        <monitor-profiles>
        <monitor-profile>Display/Video (Podcast/Vodcast/EchoPlayer). Balanced between file size &#038; quality</monitor-profile>
        </monitor-profiles>
        <next>
        <type>media</type>
        <start-time>2014-02-12T23:00:00.000Z</start-time>
        <duration>3000</duration>
        <parameters>
        <title>Underwater Basket Weaving 101 (UWBW-101-100) Spring 2014</title>
        <section ref="ec7a622a-da43-4a31-897f-841ea192f63d">Underwater Basket Weaving 101 (UWBW-101-100) Spring 2014</section>
        <presenters>
        <presenter ref="9d56966e-3b39-4e26-b0f4-58bebc3ec4de">John Doe</presenter>
        </presenters>
        <capture-profile id="830d7947-0926-487c-8c64-72b06c1de1e4">
        <name>Display/Video (Podcast/Vodcast/EchoPlayer). Optimized for quality/full motion video</name>
        <output-type>archive</output-type>
        <products>
        <product>
        <source name="audio" type="audio">
        <input>balanced</input>
        <mode>stereo</mode>
        <analog-gain>-6</analog-gain>
        <samplerate>44100</samplerate>
        <gain>0</gain>
        <agc>false</agc>
        </source>
        <source name="graphics1" type="graphics">
        <channel>1</channel>
        <input>dvi</input>
        <brightness>50</brightness>
        <contrast>50</contrast>
        <saturation>50</saturation>
        <framerate>10.0</framerate>
        <width>960</width>
        <height>720</height>
        <fix-aspect-ratio>true</fix-aspect-ratio>
        <is-display>true</is-display>
        </source>
        <source name="graphics2" type="graphics">
        <channel>2</channel>
        <input>composite</input>
        <brightness>50</brightness>
        <contrast>50</contrast>
        <saturation>50</saturation>
        <framerate>29.97</framerate>
        <width>704</width>
        <height>480</height>
        <fix-aspect-ratio>true</fix-aspect-ratio>
        <is-display>false</is-display>
        <standard>ntsc</standard>
        </source>
        <transform name="audio-archive" type="encoder">
        <input>audio</input>
        <codec>aac</codec>
        <encode-on-host>true</encode-on-host>
        <codec-parameters>
        <bitrate>128000</bitrate>
        <profile>lc</profile>
        </codec-parameters>
        </transform>
        <transform name="graphics1-archive" type="encoder">
        <input>graphics1</input>
        <codec>h264</codec>
        <codec-parameters>
        <bitrate-control>vbr</bitrate-control>
        <bitrate>736000</bitrate>
        <max-bitrate>1104000</max-bitrate>
        <profile>base</profile>
        <frames-per-keyframe>50</frames-per-keyframe>
        </codec-parameters>
        </transform>
        <transform name="graphics2-archive" type="encoder">
        <input>graphics2</input>
        <codec>h264</codec>
        <codec-parameters>
        <bitrate-control>vbr</bitrate-control>
        <bitrate>1056000</bitrate>
        <max-bitrate>1584000</max-bitrate>
        <profile>base</profile>
        <frames-per-keyframe>150</frames-per-keyframe>
        </codec-parameters>
        </transform>
        <sink name="audio-archive-file">
        <input>audio-archive</input>
        <output>
        <type>file</type>
        <filename>audio.aac</filename>
        </output>
        </sink>
        <sink name="graphics1-archive-file">
        <input>graphics1-archive</input>
        <output>
        <type>file</type>
        <filename>display.h264</filename>
        </output>
        </sink>
        <sink name="graphics2-archive-file">
        <input>graphics2-archive</input>
        <output>
        <type>file</type>
        <filename>video.h264</filename>
        </output>
        </sink>
        </product>
        </products>
        </capture-profile>
        </parameters>
        </next><current>
        <schedule>
        </schedule>
        </current>
        </status>
    HEREDOC
