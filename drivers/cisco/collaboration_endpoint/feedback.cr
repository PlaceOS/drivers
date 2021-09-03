class Cisco::CollaborationEndpoint::Feedback
  def initialize
    @callbacks = Hash(String, Array(Proc(String, Enumerable::JSONComplex, Nil))).new do |h, k|
      h[k] = [] of Proc(String, Enumerable::JSONComplex, Nil)
    end
  end

  # Nuke a subtree below the path
  def remove(path : String)
    remove = [] of String
    @callbacks.each_key { |key| remove << key if key.starts_with?(path) }
    remove.each { |key| @callbacks.delete(key) }
    self
  end

  # Insert a response handler block to be notified of updates effecting the
  # specified feedback path.
  def insert(path : String, &handler : Proc(String, Enumerable::JSONComplex, Nil))
    @callbacks[path] << handler
    self
  end

  def contains?(path : String)
    found = false
    @callbacks.each_key do |key|
      if path.starts_with? key
        found = true
        break
      end
    end
    found
  end

  def notify(path : String, value : Enumerable::JSONComplex)
    @callbacks.each do |key, callbacks|
      callbacks.each &.call(path, value) if path.starts_with? key
    end
  end

  def notify(payload : Hash(String, Enumerable::JSONComplex))
    payload.each { |key, value| notify(key, value) }
  end

  def clear
    @callbacks = Hash(String, Array(Proc(String, Enumerable::JSONComplex, Nil))).new do |h, k|
      h[k] = [] of Proc(String, Enumerable::JSONComplex, Nil)
    end
  end
end
