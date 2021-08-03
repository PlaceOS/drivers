
# Exterity AvediaPlayer r9200 Control Protocol.

NOTE:: All information in this document was obtained via exploration of the R9200 device.
No information here was provided by Exterity during this process


## Connecting

* Telnet Protocol (port 23)
* `telnet 192.168.1.13`
* Default username: `admin`
* Default password: `labrador`
* Select option `6` to run a shell


## Shell Navigation

Once in the shell you can use following tools to read files:

* `less` for scanning through files
* `cat` for dumping files
* `ps aux` for viewing processes
* `ls` for listing files

The file system is readonly so moving files to `/usr/local/www` for downloading was not possible.


## Applications

* Application are installed at: `/usr/bin`
  * `serialCommandInterface` allows programmatic control of the device
  * `irsend` for sending IR commands
* Configuration is at: `/etc`
  * `lircd.conf` contains the human readable names of all the IR commands

```
begin remote

  name     exterity_remote_2

  bits           16
  flags SPACE_ENC
  eps            20
  aeps          200

  header       8800  4400
  one           550  1650
  zero          550   550
  ptrail        550
  repeat       8800  2200
  pre_data_bits   16
  pre_data       0xB5B7
  gap          38500
  toggle_bit      0
  frequency    38000

#! exterity_bit_period        560
#! exterity_aeps              500
#! exterity_rmpower_len       66
#! exterity_rmpower_pattern   16 8 1 3 1 1 1 3 1 3 1 1 1 3 1 1 1 3 1 3 1 1 1 3 1 3 1 1 1 3 1 3 1 3 1 3 1 1 1 3 1 1 1 3 1 3 1 1 1 3 1 1 1 3 1 1 1 3 1 1 1 1 1 3 1 1

  begin codes
        rm_1              0x45ba
        rm_2              0x35ca
        rm_3              0x6d92
        rm_4              0xc53a
        rm_5              0xb54a
        rm_6              0xed12
        rm_7              0x25da
        rm_8              0x758a
        rm_9              0x1de2
        rm_cancel         0x03fc
        rm_0              0xf50a
        rm_menu           0xa55a
        rm_power          0xad52
        rm_chup           0x0df2
        rm_chdown         0x8d72
        rm_volup          0x5da2
        rm_voldown        0xdd22
        rm_up             0x4db2
        rm_left           0x956a
        rm_enter          0xcd32
        rm_right          0xbd42
        rm_down           0x2dd2
        rm_mute           0xa35c
        rm_red            0x837c
        rm_green          0x43bc
        rm_yellow         0xc33c
        rm_blue           0x23dc
        rm_rewind         0x15ea
        rm_play           0x55aa
        rm_pause          0xe51a
        rm_ff             0x3dc2
        rm_skipback       0x639c
        rm_skipfwd        0xe31c
        rm_stop           0x7d82
        rm_record         0x659a
        rm_exterity       0x13ec
        rm_fn_tv          0x936c
        rm_fn_home        0x53ac
        rm_guide          0xd32c
        rm_subtitle       0x857A
        rm_info           0x33CC
        rm_help           0xB34C
        rm_audio          0x9D62
        rm_teletext       0xD52A
        rm_av             0xFD02
  end codes

end remote

```


## Serial Command Interface

* All lines start with `^`
* All lines end with `!`

Dump of the help text:


```
^help!
To display a value: ^get:<option>!
To change a value: ^set:<option>:<value>!
To display a list of option values: ^dump!
To send a remote key press: ^send:<key>!
To send multiple remote key presses: ^msend!<n>:<key1>:<key2>:...:<keyn>!
To send a serial command to the TV: ^sendserial:<command>!
To exit session: ^exit!

Valid options for get and set commands (tag/alternate tag):
        Name    name
        Location        location
        Groups  groups
        NetworkBootProto        dhcp
        IPAddress
        Subnet  subnetMask
        Gateway gateway
        DNSPrimary
        DNSSecondary
        TFTPServer
        StartupMode     startupMode
        currentMode
        new_display
        cur_display
        DoUpgrade       upgrade
        bootfile
        AdminPassword   adminPassword
        Volume  volume
        product_type    productType
        boardtype       boardType
        boardmod        boardMod
        boardrev        boardRevision
        boardnum        boardNumber
        mac     macAddress
        serial  serialNumber
        cur_webpage     currWebpage
        new_webpage     webpage
        newpage
        currentChannel
        currentAVChannel
        new_channel
        cur_channel
        channel_up      upChannel
        channel_down    downChannel
        stop_channel    stopChannel
        play_channel_uri        playChannelUri
        play_channel_number     playChannelNumber
        Play    play
        FastForward     fastForward
        Rewind  rewind
        failover
        totalresets     totalResets
        remoteresets    remoteResets
        softresets      softResets
        Timeserver      timeserver
        video_scaler    scaleDimensions
        zapper
        galio
        serialCommandInterface
        admin
        TZ      timezone
        SoftwareVersion softwareVersion
        softwareDescription
        mute    mute
        LanguageIso639  prefAudioLang
        PrefSubtitleLang        prefSubtitleLang
        cur_audiotrack  currAudioTrack
        cur_subtitletrack       currSubtitleTrack
        PlaylistUrl     playlistUrl
        DisplayHD       HD
        UserBitmap      splashFile
        ScreenFormat    screenFormat
        AspectRatio     aspectRatio
        browser.document.default        homepage
        proxySetting
        proxy
        proxyIgnore
        transports.proxy.http.on
        transports.proxy.http
        transports.proxy.http.ignore
        transports.proxy.ftp.on
        transports.proxy.ftp
        transports.proxy.ftp.ignore
        transports.proxy.https.on
        transports.proxy.https
        transports.proxy.https.ignore
        transports.proxy.mailto.on
        transports.proxy.mailto
        controller.toolbar.on
        browserToolbar
        BrowserSize     browserSize
        TVCtrlType
        SerialConfig    serialConfig
        StandbyActionsSer       standbyActions
        UnstandbyActionsSer     unstandbyActions
        IRControllerType
        enableIRReceiver
        IRMode
        IROutControllerType
        StandbyActionsIR        standbyActionsIR
        UnstandbyActionsIR      unstandbyActionsIR
        MasterIRClient  masterIRClient
        VlanEnable      vlanEnable
        VlanNative      vlanNative
        VlanHost        vlanHost
        VlanEth2        vlanEth2
        VlanEth3        vlanEth3
        VlanEth4        vlanEth4
        Speed   speed
        Duplex  duplex
        Autoneg autoneg
        linkEth
        rxstatsEth
        txstatsEth
        SpeedEth1       speedEth1
        DuplexEth1      duplexEth1
        AutonegEth1     autonegEth1
        linkEth1
        rxstatsEth1
        txstatsEth1
        SpeedEth2       speedEth2
        DuplexEth2      duplexEth2
        AutonegEth2     autonegEth2
        linkEth2
        rxstatsEth2
        txstatsEth2
        SpeedEth3       speedEth3
        DuplexEth3      duplexEth3
        AutonegEth3     autonegEth3
        linkEth3
        rxstatsEth3
        txstatsEth3
        SpeedEth4       speedEth4
        DuplexEth4      duplexEth4
        AutonegEth4     autonegEth4
        linkEth4
        rxstatsEth4
        txstatsEth4
        configureNetworkPorts
        RemoteLog       remoteLogging
        RemoteLogAddress        remoteLogAddress
        RemoteLogPort   remoteLogPort
        LogLevel        remoteLogLevel
        TVButton
        HomeButton      homeButton
        GuideButton     guideButton
        rmTVActions
        rmHomeActions
        rmGuideActions
        SAPListener
        rStaticChannels
        staticChannels
        SAPListenAddr
        XmlChannelListUrl       xmlChannelListUrl
        NfsMountPoints  nfsMountPoints
        UsbMountPoints  usbMountPoints
        HddMountPoints  hddMountPoints
        FailOverStatus  failOverStatus
        add_nfs
        rem_nfs
        serialActions
        FailOverType    failOverType
        FailOverPlaylist        failOverPlaylist
        FailOverBrowser failOverBrowser
        FailOverMedia   failOverMedia
        NfsMountStatus  nfsMountStatus
        XmlChannelListRefresh   xmlChannelListRefresh
        LocalXmlChannelListRefresh      localXmlChannelListRefresh
        LedStatus       ledStatus
        reboot
        ScreenSaverTimeout      screenSaverTimeout
        playstream_status       playstreamStatus
        playstream_speed        playstreamSpeed
        SmServerAddress SMServerAddress
        SmServerPort    SMServerPort
        Subtitles       subtitles
        closedCaptionsDetected
        closedCaptionChannel
        savePlaylist
        clearPlaylist
        PlaylistDownloadStatus
        browserEvent
        doFactoryReset  factoryReset
        exportConfig
        importConfig
        BrowserHeap
        BrowserFlex
        screenResolution
        screenFrameRate
        teletextVBI     teletextVBI
        SNMPD   snmpEnable
        SNMP_RWCOMMUNITY        snmpRWCommunity
        SNMP_ROCOMMUNITY        snmpROCommunity
        usbMount
        currentScreenResolution
        lastScreenResolution
        outputScreenResolution
        currentScreenFrameRate
        upTime
        Date
        SNMPManager
        SNMPTrapManager snmpTrapManager
        usbFileSize
        usbSpaceLeft
        hasSwitchChip
        timeServerInUse
        devel
        updateChannelsList
        stopOnDestroy
        serialMode
        serialTVStatus
        dcardType
        dcardSerial
        dcardRev
        dcardMod
        hdmiState
        playLength
        playPosition
        43AspectDisplay
        SSM_Uri
        CECAmpenabled
        CECStandbyenabled
        CECVolumeChanged
        CECStatus
        CECRequestActiveSrc
        CECSendCmd
        CECRequestStandby
        vodFeed
        uiLang
        subtitlesShow
        DeviceType      deviceType
        animateUI
        webAccess
        USBStorageAccess
        remoteMode
        sourceIPAddr
        sendKey
        factoryResetButton
        securitySetting
        ApplyPage
        CAP_VLAN
        net_stats
        channel_learning_addrs
        product_string
        font_files
        del_font_files
        resource_used
        resource_total
        stream_type
        stream_info
        tv_info
        decode_state
        last_decode_state
        playState
        edidStatus
        rtpErrCount
        current_font
        bookmarkOne
        bookmarkTwo
        bookmarkThree
        caching
        tolerance
        teletext
        teletextAvailable
        teletextPageDigit
        teletextPageDigitReset
        teletextNavigate
        teletextPage
        teletextZoom
        teletextHoldSubpage
        Licence
        videoWallXPosition
        videoWallYPosition
        videoWallXSize
        videoWallYSize
        vwTopBezelPercent
        vwLeftBezelPercent
        vwRightBezelPercent
        vwBottomBezelPercent
        importConfigFile
        exportConfigFile
        serialPort
        dnslookup
        setFuse
        readJTAG
        protect
        hasStarted
        ConfigVersion
        SNMPConfigChangeText
```

