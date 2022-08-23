require "placeos-driver"
require "sabo"

class Infosilem::Campus < PlaceOS::Driver
  descriptive_name "Infosilem Campus Gateway"
  generic_name :Campus
  uri_base "https://example.com/InfosilemCampus/API"

  alias Client = Sabo::Client

  default_settings({
    username: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    password: "ABCDEF123456",
  })

  protected getter! integration : Client
  protected getter! booking : Client

  def on_load
    on_update
  end

  def on_update
    host_name = config.uri.not_nil!.to_s

    @integration = Sabo::Client.new(
      document: Sabo::WSDL::Document.new([host_name, "/Integration/Integration.asmx?WSDL"].join),
      prefix: "http://www.infosilem.com/",
      version: "1.2"
    )

    @booking = Sabo::Client.new(
      document: Sabo::WSDL::Document.new([host_name, "/ExportOnly/RoomBookingPub.asmx?WSDL"].join),
      prefix: "http://www.infosilem.com/",
      version: "1.2"
    )
  end

  def bookings?(room_id : String, start_date : String, end_date : String)
    response = @integration.try(&.call(operation: "StartTransfer", body: {"StartTransferOptions" => Sabo::Parameter.from_hash(start_transfer_options(username: setting(String, :username), password: setting(String, :password)))}))
    transfer_id = response.try(&.result)

    response = @booking.try(&.call(operation: "RoomBookingOccurrence_ExportAll", body: {
      "TransferID" => Sabo::Parameter.new(transfer_id.to_s),
      "Options"    => Sabo::Parameter.from_hash(booking_options(room: room_id, start_date: start_date, end_date: end_date, start_time: start_date, end_time: end_date)),
    }
    ))

    @integration.try(&.call(operation: "EndTransfer", body: end_transfer_body(transfer_id: transfer_id.to_s)))

    response.try(&.result
          .["ObjectData"]
          .["ReservationOccurrences"]
          .["ReservationOccurrence"]?) || [] of Int32
  end

  private def start_transfer_options(
    username : String = "",
    password : String = "",
    description_resource_id : String = "",
    for_import : Bool = false,
    allow_same_concurrent_import : Bool = false,
    queued_timeout : Int32 = 15,
    log_unchanged_rows : Bool = true,
    log_rejected_records_xml : Bool = true
  )
    {
      "Username"                  => username,
      "Password"                  => password,
      "DesciptionResourceID"      => description_resource_id,
      "ForImport"                 => for_import,
      "AllowSameConcurrentImport" => allow_same_concurrent_import,
      "QueuedTimeout"             => queued_timeout,
      "LogUnchangedRows"          => log_unchanged_rows,
      "LogRejectedRecordsXML"     => log_rejected_records_xml,
    }
  end

  private def end_transfer_body(transfer_id : String)
    {
      "TransferID"     => Sabo::Parameter.new(transfer_id),
      "EmailAddresses" => Sabo::Parameter.from_array([] of String),
      "SendSummary"    => Sabo::Parameter.new(true),
      "SummaryStyle"   => Sabo::Parameter.new(""),
      "SendDetails"    => Sabo::Parameter.new(true),
      "DetailsStyle"   => Sabo::Parameter.new(""),
      "SendRejects"    => Sabo::Parameter.new(true),
      "RejectsStyle"   => Sabo::Parameter.new(""),
    }
  end

  private def booking_options(
    export_as_object : Bool = true,
    compress_export : Bool = true,
    room : String = "",
    building : String = "",
    campus : String = "",
    event_filter : String = "",
    start_time : String = "",
    end_time : String = "",
    use_time_filter : Bool = false,
    start_date : String = "",
    end_date : String = "",
    event_id : String = "",
    activity_id : String = ""
  )
    {
      "ExportAsObject"   => export_as_object,
      "CompressedExport" => compress_export,
      "Room"             => room,
      "Building"         => building,
      "Campus"           => campus,
      "EventFilter"      => event_filter,
      "StartTime"        => start_time,
      "EndTime"          => end_time,
      "UseTimeFilter"    => use_time_filter,
      "StartDate"        => start_date,
      "EndDate"          => end_date,
      "EventID"          => event_id,
      "ActivityID"       => activity_id,
    }
  end
end
