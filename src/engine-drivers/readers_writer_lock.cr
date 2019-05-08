# Allows multiple readers and only a single writer
class EngineDrivers::ReadersWriterLock
  def initialize
    @readers = 0
    @reader_lock = Mutex.new
    @writer_lock = Mutex.new
  end

  def readers
    @reader_lock.synchronize { @readers }
  end

  # Read locks
  def read
    @writer_lock.synchronize do
      @reader_lock.synchronize { @readers += 1 }
    end

    yield
  ensure
    @reader_lock.synchronize { @readers -= 1 }
  end

  # Write lock
  def synchronize
    write do
      yield
    end
  end

  def write
    @writer_lock.synchronize do
      write_ready = false
      loop do
        @reader_lock.synchronize { write_ready = @readers == 0 }
        break if write_ready

        # Wait a short amount of time
        Fiber.yield
      end

      yield
    end
  end
end
