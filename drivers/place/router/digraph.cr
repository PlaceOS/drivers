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

  # Prints the graph connectectivy as DOT.
  def to_s(io)
    io << "digraph {\n"
    @nodes.each do |id, n|
      io << "  "
      io << id
      unless n.succ.empty?
        io << " -> { "
        n.succ.keys.join(io, ' ')
        io << " }"
      end
      io << ";\n"
    end
    io << '}'
  end

  # Retrieves the label attached to node *id*.
  def [](id)
    fetch(id) { raise KeyError.new "Node #{id} does not exist" }
  end

  # Retrieves the label attached to node *id*. Yields if it does not exist.
  def fetch(id, &) : N
    id = id.to_u64
    node = @nodes[id]?
    node ? node.attr : yield id
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
      raise KeyError.new "Edge #{pred_id} -> #{succ_id} does not exist"
    end
  end

  # :ditto:
  def fetch(pred_id, succ_id, &) : E
    pred_id = pred_id.to_u64
    succ_id = succ_id.to_u64
    if pred = @nodes[pred_id]?
      pred.succ.fetch(succ_id) { yield pred_id, succ_id }
    else
      yield pred_id, succ_id
    end
  end

  # Inserts an edge.
  def []=(pred_id, succ_id, attr)
    insert(pred_id, succ_id, attr) do
      raise Error.new "Edge #{pred_id} -> #{succ_id} already exists"
    end
  end

  # :ditto:
  def insert(pred_id, succ_id, attr : E, &)
    pred_id = pred_id.to_u64
    succ_id = succ_id.to_u64

    unless @nodes.has_key? succ_id
      raise KeyError.new "Node #{succ_id} does not exist"
    end
    pred = @nodes.fetch(pred_id) do
      raise KeyError.new "Node #{pred_id} does not exist"
    end

    if pred.succ.has_key? succ_id
      yield pred_id, succ_id
    else
      pred.succ[succ_id] = attr
    end
  end

  # Returns a list of node IDs that form the shortest path between the passed
  # nodes or `nil` if no path exists.
  def path(from, to, invert = false) : Array(UInt64)?
    from = from.to_u64
    to = to.to_u64

    raise Error.new "Node #{from} does not exist" unless @nodes.has_key? from
    raise Error.new "Node #{to} does not exist" unless @nodes.has_key? to

    paths = Hash(UInt64, UInt64).new
    queue = Deque(UInt64).new

    # BFS for *to* starting from *from*.
    queue << from
    while pred_id = queue.shift?
      @nodes[pred_id].succ.each_key do |succ_id|
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
