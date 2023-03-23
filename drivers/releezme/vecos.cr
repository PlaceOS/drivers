require "placeos-driver"
require "vecos"

class Releezme::Vecos < PlaceOS::Driver
  descriptive_name "Releezme Vecos Gateway"
  generic_name :Management

  alias Client = ::Vecos::Client

  default_settings({
    client_id:     "8537d5c8-a85c-4657-bc6b-7c35b1405464",
    client_secret: "856b5b85d3eb4697369",
    username:      "admin",
    password:      "admin",
  })

  protected getter! client : Client

  def on_load
    on_update
  end

  def on_update
    client_id = setting(String, :client_id)
    client_secret = setting(String, :client_secret)
    username = setting(String, :username)
    password = setting(String, :password)

    @client = Client.new(client_id: client_id, client_secret: client_secret, username: username, password: password)
  end

  def get_allocatable_locker_groups_in_locker_bank(section_id : String, external_user_id : String, page_number : Int32 = 0, page_size : Int32 = 10)
    client.sections.list_allocatable_locker_bank_locker_groups(section_id, external_user_id, page_number, page_size)
  end

  def get_locker_bank_status(locker_bank_id : String)
    client.locker_banks.get_status(locker_bank_id)
  end

  def get_allocated_lockers(external_user_id : String, page_number : Int32 = 0, page_size : Int32 = 10)
    client.lockers.allocated(external_user_id, page_number, page_size)
  end

  def share_locker(locker_id : String, external_user_id : String, shared_user_id : String)
    client.lockers.share_by_path(locker_id, external_user_id, shared_user_id)
  end
end
