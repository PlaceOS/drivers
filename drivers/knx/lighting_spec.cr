require "placeos-driver/spec"

# :nodoc:
class KNXMock < DriverSpecs::MockDriver
  def action(address : String, data : Bool | Int32 | Float32 | String) : Nil
    case data
    in Int32
      io = IO::Memory.new(4)
      io.write_bytes data, IO::ByteFormat::BigEndian
      self[address] = io.to_slice.hexstring
    in Bool
      self[address] = data ? "01" : "00"
    in Float32, String
      raise "types not being tested"
    end
  end

  def status(address : String) : Nil
    self[address]?
  end
end

DriverSpecs.mock_driver "KNX::Lighting" do
  system({
    KNX: {KNXMock},
  })

  exec(:set_lighting_scene, 2).get
  sleep 0.1
  status["area_4/1/33"].should eq 2

  exec(:set_lighting_level, 100).get
  sleep 0.1
  status["area_4/1/66"].should eq 100

  exec(:lighting_level?).get.should eq 100
  exec(:lighting_level?, {component: "4/1/66"}).get.should eq 100

  exec(:lighting_scene?).get.should eq 2
  exec(:lighting_scene?, {component: "4/1/33"}).get.should eq 2
end
