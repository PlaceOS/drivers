require "json"

# Models of the PlaceOS payment driver contract and of the Stripe API.
#
# The contract types copy `libs/payments/src/lib/payment.types.ts` of
# https://github.com/PlaceOS/user-interfaces. See `docs/payments.md` there.
#
# - Amounts are integers in the minor unit of the currency, e.g. cents.
# - Currencies are upper case ISO 4217 codes, e.g. `AUD`.
# - Times are unix seconds.
module Stripe
  # ===================================
  # Driver contract
  # ===================================

  enum PaymentStatus
    Pending
    RequiresAction
    Authorized
    Succeeded
    PartiallyRefunded
    Refunded
    Cancelled
    Failed
  end

  enum ResourceType
    Room
    Desk
    Parking
    Locker
    Catering
    Asset
    Service
  end

  enum PaymentUnit
    Booking
    Hour
    Day
    Item
  end

  enum InvoiceStatus
    Requested
    Draft
    Open
    Paid
    Void
  end

  # Settings of the driver for the current user
  record PaymentConfig, provider : String, currency : String, privileged : Bool, capabilities : Array(String) do
    include JSON::Serializable
  end

  # Something to pay for. The driver finds the product and calculates the price
  struct LineItemRequest
    include JSON::Serializable

    getter resource_type : ResourceType
    getter product_id : String? = nil
    getter resource_id : String? = nil
    getter zone_id : String? = nil
    getter start : Int64? = nil
    # length of the booking in minutes
    getter duration : Int32? = nil
    getter quantity : Int32? = nil
    getter option_ids : Array(String)? = nil
    getter name : String? = nil

    def initialize(@resource_type, @product_id = nil, @resource_id = nil, @zone_id = nil, @duration = nil, @quantity = nil, @option_ids = nil, @name = nil)
    end
  end

  # Line item with the price that the driver calculated
  struct LineItem
    include JSON::Serializable

    getter product_id : String
    getter resource_type : ResourceType
    getter resource_id : String
    getter name : String
    getter description : String
    getter unit : PaymentUnit
    getter quantity : Int32
    getter unit_amount : Int64
    # `unit_amount` multiplied by `quantity`
    getter amount : Int64

    def initialize(@product_id, @resource_type, @resource_id, @name, @description, @unit, @quantity, @unit_amount)
      @amount = @unit_amount * @quantity
    end
  end

  record PaymentQuote, currency : String, items : Array(LineItem), subtotal : Int64, tax : Int64, total : Int64 do
    include JSON::Serializable
  end

  # What a payment pays for
  struct PaymentReference
    include JSON::Serializable

    getter type : String
    getter id : String
    getter zone_id : String? = nil

    def initialize(@type, @id, @zone_id = nil)
    end

    def_equals type, id
  end

  struct CheckoutRequest
    include JSON::Serializable

    getter idempotency_key : String
    getter items : Array(LineItemRequest)
    getter expected_total : Int64
    getter description : String
    getter payment_method_id : String? = nil
    getter save_method : Bool? = nil
    getter return_url : String
    getter cancel_url : String
  end

  record CheckoutSession, payment_id : String, status : PaymentStatus, expires_at : Int64, url : String? = nil do
    include JSON::Serializable
  end

  # Hosted page, e.g. to add a payment method
  record HostedSession, id : String, url : String, expires_at : Int64 do
    include JSON::Serializable
  end

  struct PaymentMethod
    include JSON::Serializable

    getter id : String
    getter type : String
    getter brand : String
    getter last4 : String
    getter exp_month : Int32
    getter exp_year : Int32
    getter is_default : Bool

    def initialize(@id, @type, @brand, @last4, @exp_month, @exp_year, @is_default)
    end
  end

  record MethodSummary, type : String, brand : String, last4 : String do
    include JSON::Serializable
  end

  struct Payment
    include JSON::Serializable

    getter id : String
    getter status : PaymentStatus
    getter amount : Int64
    getter amount_refunded : Int64
    getter currency : String
    getter description : String
    getter items : Array(LineItem)
    getter user_id : String
    getter user_email : String
    getter user_name : String
    getter reference : PaymentReference? = nil
    getter payment_method : MethodSummary? = nil
    getter receipt_url : String? = nil
    getter invoice_id : String? = nil
    getter created_at : Int64
    getter updated_at : Int64

    def initialize(@id, @status, @amount, @amount_refunded, @currency, @description, @items, @user_id, @user_email, @user_name, @reference, @payment_method, @receipt_url, @invoice_id, @created_at, @updated_at)
    end
  end

  # Filters for a list of payments
  struct PaymentQuery
    include JSON::Serializable

    getter user_email : String? = nil
    getter status : PaymentStatus? = nil
    getter reference_id : String? = nil
    getter period_start : Int64? = nil
    getter period_end : Int64? = nil
    getter limit : Int32? = nil
    getter cursor : String? = nil
  end

  # One page of a list. `next_cursor` is not set on the last page
  record PaymentPage(T), items : Array(T), next_cursor : String? = nil do
    include JSON::Serializable
  end

  struct BillingDetails
    include JSON::Serializable

    getter name : String
    getter email : String
    getter company : String? = nil
    getter tax_id : String? = nil
    getter address : String? = nil

    def initialize(@name, @email, @company = nil, @tax_id = nil, @address = nil)
    end
  end

  struct Invoice
    include JSON::Serializable

    getter id : String
    getter number : String
    getter status : InvoiceStatus
    getter payment_id : String? = nil
    getter user_email : String
    getter user_name : String
    getter amount : Int64
    getter currency : String
    getter items : Array(LineItem)
    getter billing : BillingDetails? = nil
    getter memo : String
    getter url : String? = nil
    getter pdf_url : String? = nil
    getter created_at : Int64
    getter sent_at : Int64? = nil
    getter due_at : Int64? = nil

    def initialize(@id, @number, @status, @payment_id, @user_email, @user_name, @amount, @currency, @items, @billing, @memo, @url, @pdf_url, @created_at, @sent_at, @due_at)
    end
  end

  struct InvoiceQuery
    include JSON::Serializable

    getter user_email : String? = nil
    getter status : InvoiceStatus? = nil
    getter payment_id : String? = nil
    getter limit : Int32? = nil
    getter cursor : String? = nil
  end

  # New invoice for products or services that a user must pay
  struct InvoiceCreateRequest
    include JSON::Serializable

    getter user_email : String
    getter user_name : String? = nil
    getter items : Array(LineItemRequest)
    getter memo : String? = nil
    getter due_days : Int32
    getter send : Bool
  end

  struct PaymentProduct
    include JSON::Serializable

    getter id : String
    getter name : String
    getter description : String
    getter active : Bool
    getter resource_type : ResourceType
    # empty applies to all resources of the type
    getter resource_ids : Array(String)
    # empty applies to all zones
    getter zone_ids : Array(String)
    getter unit : PaymentUnit
    getter unit_amount : Int64
    getter currency : String
    getter created_at : Int64
    getter updated_at : Int64

    def initialize(@id, @name, @description, @active, @resource_type, @resource_ids, @zone_ids, @unit, @unit_amount, @currency, @created_at, @updated_at)
    end
  end

  # Product to save. Without an `id`, the driver makes a new product
  struct PaymentProductInput
    include JSON::Serializable

    getter id : String? = nil
    getter name : String
    getter description : String = ""
    getter active : Bool = true
    getter resource_type : ResourceType
    getter resource_ids : Array(String) = [] of String
    getter zone_ids : Array(String) = [] of String
    getter unit : PaymentUnit
    getter unit_amount : Int64
    getter currency : String
  end

  struct ProductQuery
    include JSON::Serializable

    getter resource_type : ResourceType? = nil
    getter include_inactive : Bool? = nil
  end

  # ===================================
  # PlaceOS
  # ===================================

  # The fields of a PlaceOS user that the driver needs
  struct PlaceUser
    include JSON::Serializable

    getter id : String
    getter email : String
    getter name : String
    getter groups : Array(String)? = nil
    getter sys_admin : Bool? = nil
  end

  struct PlaceZone
    include JSON::Serializable

    getter id : String
    getter parent_id : String? = nil
  end

  struct PlaceAssetType
    include JSON::Serializable

    getter id : String
    getter name : String
  end

  struct CateringOption
    include JSON::Serializable

    getter id : String
    getter name : String = ""
    # cents. JSON can hold it as a float
    getter unit_price : Float64? = nil
  end

  struct CateringData
    include JSON::Serializable

    # cents. JSON can hold it as a float
    getter unit_price : Float64? = nil
    getter options : Array(CateringOption)? = nil
  end

  # Catering menu item. The `CATERING:<caterer>` asset types hold the menu
  struct PlaceAsset
    include JSON::Serializable

    getter id : String
    getter name : String? = nil
    getter other_data : CateringData? = nil
  end

  # ===================================
  # Stripe API (version `Stripe::Payments::API_VERSION`)
  # https://docs.stripe.com/api
  # ===================================

  struct StripeError
    include JSON::Serializable

    getter message : String? = nil
    getter type : String? = nil
    getter code : String? = nil
  end

  struct ErrorResponse
    include JSON::Serializable

    getter error : StripeError
  end

  # A list or search result. Search returns `next_page`, lists use `has_more`
  struct StripeList(T)
    include JSON::Serializable

    getter data : Array(T)
    getter has_more : Bool = false
    getter next_page : String? = nil
  end

  struct Customer
    include JSON::Serializable

    struct InvoiceSettings
      include JSON::Serializable

      getter default_payment_method : String? = nil
    end

    getter id : String
    getter email : String? = nil
    getter name : String? = nil
    getter metadata : Hash(String, String) = {} of String => String
    getter invoice_settings : InvoiceSettings? = nil
  end

  struct Card
    include JSON::Serializable

    getter brand : String = ""
    getter last4 : String = ""
    getter exp_month : Int32 = 0
    getter exp_year : Int32 = 0
  end

  struct StripePaymentMethod
    include JSON::Serializable

    getter id : String
    getter type : String
    getter customer : String? = nil
    getter card : Card? = nil
  end

  struct Charge
    include JSON::Serializable

    struct Details
      include JSON::Serializable

      getter type : String = ""
      getter card : Card? = nil
    end

    getter id : String
    getter amount : Int64 = 0
    getter amount_captured : Int64 = 0
    getter amount_refunded : Int64 = 0
    getter receipt_url : String? = nil
    getter payment_method_details : Details? = nil
  end

  struct NextAction
    include JSON::Serializable

    struct Redirect
      include JSON::Serializable

      getter url : String
    end

    getter type : String
    getter redirect_to_url : Redirect? = nil
  end

  struct PaymentIntent
    include JSON::Serializable

    getter id : String
    getter status : String
    getter amount : Int64
    getter amount_received : Int64 = 0
    getter currency : String
    getter customer : String? = nil
    getter description : String? = nil
    getter metadata : Hash(String, String) = {} of String => String
    getter next_action : NextAction? = nil
    getter last_payment_error : StripeError? = nil
    # an ID, or the charge when the request expands it
    getter latest_charge : String | Charge | Nil = nil
    getter created : Int64

    def charge : Charge?
      latest_charge.as?(Charge)
    end
  end

  struct CheckoutSessionObject
    include JSON::Serializable

    getter id : String
    getter status : String? = nil
    getter url : String? = nil
    getter amount_total : Int64? = nil
    getter currency : String? = nil
    getter customer : String? = nil
    getter metadata : Hash(String, String) = {} of String => String
    # an ID, or the PaymentIntent when the request expands it
    getter payment_intent : String | PaymentIntent | Nil = nil
    getter expires_at : Int64
    getter created : Int64

    def intent : PaymentIntent?
      payment_intent.as?(PaymentIntent)
    end
  end

  struct Refund
    include JSON::Serializable

    getter id : String
    getter status : String? = nil
    getter metadata : Hash(String, String) = {} of String => String
  end

  struct Price
    include JSON::Serializable

    getter id : String
    getter unit_amount : Int64? = nil
    getter currency : String
  end

  struct Product
    include JSON::Serializable

    getter id : String
    getter name : String
    getter description : String? = nil
    getter active : Bool
    getter metadata : Hash(String, String) = {} of String => String
    # an ID, or the price when the request expands it
    getter default_price : String | Price | Nil = nil
    getter created : Int64
    getter updated : Int64

    def price : Price?
      default_price.as?(Price)
    end
  end

  struct StripeInvoice
    include JSON::Serializable

    struct Transitions
      include JSON::Serializable

      getter finalized_at : Int64? = nil
    end

    getter id : String
    getter number : String? = nil
    getter status : String? = nil
    getter customer : String? = nil
    getter customer_email : String? = nil
    getter customer_name : String? = nil
    getter total : Int64 = 0
    getter currency : String
    getter description : String? = nil
    getter metadata : Hash(String, String) = {} of String => String
    getter hosted_invoice_url : String? = nil
    getter invoice_pdf : String? = nil
    getter status_transitions : Transitions? = nil
    getter due_date : Int64? = nil
    getter created : Int64
  end
end
