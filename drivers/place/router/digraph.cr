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
    node = node(id) { |id| return yield id }
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

  # Returns a list of node IDs that form the shortest path between the passed
  # nodes or `nil` if no path exists.
  def path(from, to, invert = false) : Array(UInt64)?
    from = check_node_exists from
    to = check_node_exists to

    paths = Hash(UInt64, UInt64).new
    queue = Deque(UInt64).new

    # BFS for *to* starting from *from*.
    queue << from
    while pred_id = queue.shift?
      node(pred_id).succ.each_key do |succ_id|
        next if paths.has_key? succ_id

        paths[succ_id] = pred_id

        if succ_id == to
          # Unwind the path captured in the hash.
          nodes = [succ_id]
          until nodes.last == from
            nodes << paths[nodes.last]
          end
          nodes.reverse! unless invert
          return nodes
        end

        queue << succ_id
      end
    end

    nil
  end

  # Iterates the node labels that lay along the shortest path between two nodes.
  def nodes(from, to) : Iterator(N)?
    path(from, to).try &.each.map { |id| self[id] }
  end

  # Iterates the edge labels that lay along the shortest path between two nodes.
  def edges(from, to) : Iterator(E)?
    path(from, to).try &.each_cons(2, true).map { |(p, s)| self[p, s] }
  end
end
