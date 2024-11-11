# Labelled digraph. Holds node labels of type *N* and edge labels of type *E*.
#
# Nodes are stored on UInt64 ID's. This provides an interface that should feel
# similar to `Indexable` for interacting with nodes labels. Similarly edges can
# be placed and retrieved by using a dual index of {predescessor, successor}.
#
# OPTIMIZE: replace with a sparse matrix and graphBLAS operations.
class Place::Router::Digraph(N, E)
  class Error < Exception; end

  record Node(N, E),
    attr : N,
    succ : Hash(UInt64, E)

  @nodes : Hash(UInt64, Node(N, E))

  delegate clear, to: @nodes

  def initialize(initial_capacity = nil)
    @nodes = Hash(UInt64, Node(N, E)).new initial_capacity: initial_capacity
  end

  private def node(id)
    node(id) { raise Error.new "Node #{id} does not exist" }
  end

  private def node(id, &)
    id = id.to_u64
    @nodes.fetch(id) { yield id }
  end

  private def check_node_exists(id)
    check_node_exists(id) { raise Error.new "Node #{id} does not exist" }
  end

  private def check_node_exists(id, &)
    id = id.to_u64
    @nodes.has_key?(id) ? id : yield id
  end

  # Retrieves the label attached to node *id*.
  def [](id)
    node(id).attr
  end

  # Retrieves the label attached to node *id*. Yields if it does not exist.
  def fetch(id, &) : N
    node = node(id) { return yield id }
    node.attr
  end

  # Insert a new node.
  def []=(id, attr)
    insert(id, attr) { raise Error.new "Node #{id} already exists" }
  end

  # Inserts a node. Yields if it already exists.
  def insert(id, attr : N, &)
    id = id.to_u64
    if @nodes.has_key? id
      yield id
    else
      @nodes[id] = Node(N, E).new attr, {} of UInt64 => E
    end
  end

  # Retrieves the label attached to the edge that joins *pred_id* and *succ_id*.
  def [](pred_id, succ_id)
    fetch(pred_id, succ_id) do
      raise Error.new "Edge #{pred_id} -> #{succ_id} does not exist"
    end
  end

  # :ditto:
  def fetch(pred_id, succ_id, &) : E
    succ_id = check_node_exists succ_id
    node(pred_id).succ.fetch(succ_id) { yield pred_id, succ_id }
  end

  # Inserts an edge.
  def []=(pred_id, succ_id, attr)
    insert(pred_id, succ_id, attr) do
      raise Error.new "Edge #{pred_id} -> #{succ_id} already exists"
    end
  end

  # :ditto:
  def insert(pred_id, succ_id, attr : E, &)
    succ_id = check_node_exists succ_id
    pred = node pred_id
    if pred.succ.has_key? succ_id
      yield pred_id, succ_id
    else
      pred.succ[succ_id] = attr
    end
  end

  # Perform a breadth first search across the graph, starting at *from*.
  #
  # Each node id is yielded as it's traversed. The search will terminate when
  # this block returns true. If `nil` is returned the node is skipped, but the
  # traversal continues.
  #
  # Results are provided as a Hash that includes all reached nodes as the keys,
  # and their predecessor as the associated value.
  def breadth_first_search(from, & : UInt64 -> Bool?)
    paths = Hash(UInt64, UInt64).new
    queue = Deque(UInt64).new 1, from

    while pred_id = queue.shift?
      node(pred_id).succ.each_key do |succ_id|
        # Already visited
        next if paths.has_key? succ_id

        done = yield succ_id

        next if done.nil?

        paths[succ_id] = pred_id

        return paths if done

        queue << succ_id
      end
    end
  end

  # Returns a list of node IDs that form the shortest path between the passed
  # nodes or `nil` if no path exists.
  def path(from, to, invert = false) : Enumerable(UInt64)?
    from = check_node_exists from
    to = check_node_exists to

    paths = breadth_first_search from, &.== to
    return if paths.nil?

    # Unwind the path captured in the hash.
    nodes = [to]
    until nodes.last == from
      nodes << paths[nodes.last]
    end

    invert ? nodes : nodes.reverse!
  end

  # Provides all nodes present within the graph.
  #
  # NOTE: ordering of nodes is _not_ defined.
  def nodes : Enumerable(UInt64)
    @nodes.each_key
  end

  # Checks if a node has incoming edges only.
  def sink?(id) : Bool
    outdegree(id).zero? && !indegree(id).zero?
  end

  # Provides all nodes with incoming edges only.
  def sinks : Enumerable(UInt64)
    nodes.select { |id| sink? id }
  end

  # Checks if a node has outgoing edges only.
  def source?(id) : Bool
    !outdegree(id).zero? && indegree(id).zero?
  end

  # Provides all nodes with outgoing edges only.
  #
  # OPTIMIZE: this is _very_ slow [O(V * E)], but works for testing purposes.
  # Switching the sparse matrix should assist so not worth optimising for this
  # setup.
  def sources : Enumerable(UInt64)
    nodes.select { |id| source? id }
  end

  # The outgoing edges from *id*.
  def outdegree(id)
    node(id).succ.size
  end

  # The number of incomming edges to *id*.
  def indegree(id)
    id = check_node_exists id
    @nodes.reduce(0) do |count, (_, node)|
      count += 1 if node.succ.has_key? id
      count
    end
  end

  # Provides all nodes reachable from *id*.
  def subtree(id) : Enumerable(UInt64)
    id = check_node_exists id
    SubtreeIterator.new self, id
  end

  private class SubtreeIterator
    include Iterator(UInt64)

    @ch = Channel(UInt64).new

    def initialize(g, id)
      spawn do
        g.breadth_first_search id do |node|
          begin
            @ch.send node
            false
          rescue Channel::ClosedError
            true
          end
        end
        @ch.close unless @ch.closed?
      end
    end

    def finalize
      @ch.close unless @ch.closed?
    end

    def next
      @ch.receive? || stop
    end
  end
end
