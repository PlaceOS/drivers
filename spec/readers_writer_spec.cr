require "./spec_helper"

describe EngineDrivers::ReadersWriterLock do
  it "should isolate writes from reads" do
    lock = EngineDrivers::ReadersWriterLock.new

    spawn do
      lock.read { sleep 1 }
    end

    spawn do
      lock.read { sleep 1 }
    end

    Fiber.yield

    lock.readers.should eq(2)
    lock.write { lock.readers.should eq(0) }
    spawn do
      lock.read { sleep 1 }
    end

    Fiber.yield

    lock.readers.should eq(1)
  end
end
