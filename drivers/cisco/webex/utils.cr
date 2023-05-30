module Cisco
  module Webex
    module Utils
      def self.hash_from_items_with_values(**kwargs)
        kwargs = kwargs.map { |k, v|
          if v != nil && v != ""
            {"#{k}" => v}
          end
        }

        kwargs.reject!(nil)
        kwargs = kwargs.reduce { |acc, i| acc.try(&.merge(i.not_nil!)) }

        kwargs
      end

      def self.named_tuple_from_hash(hash)
        named_tuple = NamedTuple.new(roomId: String, text: String)
        named_tuple.from(hash)
      end
    end
  end
end
