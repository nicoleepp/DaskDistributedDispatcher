##############################            SERVER              ##############################

"""
    Server

Abstract type to listen for and handle incoming messages.
"""
@compat abstract type Server end

"""
    start_listening(server::Server)

Listen for incoming connections on a port and dispatches them to be handled.
"""
function start_listening(server::Server)
    @async begin
        while isopen(server.listener)
            try
                sock = accept(server.listener)
                handle_comm(server, sock)
            catch exception
                # Exit gracefully when worker is closed while waiting on accept.
                !isopen(server.listener) || rethrow(exception)
            end
        end
    end
end

"""
    handle_comm(server::Server, comm::TCPSocket)

Listen for incoming messages on an established connection.
"""
function handle_comm(server::Server, comm::TCPSocket)
    @async begin
        while isopen(comm)
            msg = recv_msg(comm)

            op = pop!(msg, "op", nothing)
            if op == "close"
                close(comm)
                break
            end

            msg = Dict(parse(k) => parse(v) for (k,v) in msg)

            handler = server.handlers[op]
            result = handler(server, comm; msg...)

            send_msg(comm, result)
        end
    end
end

##############################             RPC                ##############################

"""
    Rpc

Manage open socket connections to a specific address.
"""
type Rpc
    sockets::Array{TCPSocket, 1}
    address::Address
end

"""
    Rpc(address::Address) -> Rpc

Manage, open, and reuse socket connections to a specific address as required.
"""
Rpc(address::Address) = Rpc(Array{TCPSocket, 1}(), address)

"""
    send_recv(rpc::Rpc, msg::Dict) -> Dict

Send `msg` and wait for a response.
"""
function send_recv(rpc::Rpc, msg::Dict)
    comm = get_comm(rpc)
    response = send_recv(comm, msg)
    push!(rpc.sockets, comm)  # Mark as not in use
    return response
end

"""
    start_comm(rpc::Rpc) -> TCPSocket

Start a new socket connection.
"""
start_comm(rpc::Rpc) = connect(rpc.address)

"""
    get_comm(rpc::Rpc) -> TCPSocket

Reuse a previously open connection if available, if not, start a new one.
"""
function get_comm(rpc::Rpc)
    # Get rid of closed sockets
    filter!(sock -> isopen(sock), rpc.sockets)

    # Reuse sockets no longer in use
    sock = !isempty(rpc.sockets) ? pop!(rpc.sockets) : start_comm(rpc)
    return sock
end

"""
    Base.close(rpc::Rpc)

Close all communications.
"""
function Base.close(rpc::Rpc)
    for comm in rpc.sockets
        close_comm(comm)
    end
end

##############################      CONNECTION POOL           ##############################

"""
    ConnectionPool

Manage a limited number pool of TCPSocket connections to different addresses.
Default number of open connections allowed is 50.
"""
type ConnectionPool
    num_open::Integer
    num_active::Integer
    num_limit::Integer
    available::DefaultDict{Address, Set}
    occupied::DefaultDict{Address, Set}
end

"""
    ConnectionPool(limit::Integer=50) -> ConnectionPool

Return a new `ConnectionPool` which limits the total possible number of connections open
to `limit`.
"""
function ConnectionPool(;limit::Integer=50)
    ConnectionPool(
        0,
        0,
        limit,
        DefaultDict{Address, Set}(Set),
        DefaultDict{Address, Set}(Set),
    )
end

"""
    send_recv(pool::ConnectionPool, address::String, msg::Dict) -> Dict

Send `msg` to `address` and wait for a response.
"""
function send_recv(pool::ConnectionPool, address::Address, msg::Dict)
    comm = get_comm(pool, address)
    response = Dict()
    try
        response = send_recv(comm, msg)
    finally
        reuse(pool, address, comm)
    end
    return response
end

"""
    get_comm(pool::ConnectionPool, address::Address)

Get a TCPSocket connection to the given address.
"""
function get_comm(pool::ConnectionPool, address::Address)
    while !isempty(pool.available[address])
        comm = pop!(pool.available[address])
        if isopen(comm)
            pool.num_active += 1
            push!(pool.occupied[address], comm)
            return comm
        else
            pool.num_open -= 1
        end
    end

    while pool.num_open >= pool.num_limit
        collect_comms(pool)
    end

    pool.num_open += 1
    comm = connect(address)

    pool.num_active += 1
    push!(pool.occupied[address], comm)

    return comm
end

"""
    reuse(pool::ConnectionPool, address::Address, comm::TCPSocket)

Reuse an open communication to the given address.
"""
function reuse(pool::ConnectionPool, address::Address, comm::TCPSocket)
    delete!(pool.occupied[address], comm)
    pool.num_active -= 1
    if !isopen(comm)
        pool.num_open -= 1
    else
        push!(pool.available[address], comm)
    end
end

"""
    collect_comms(pool::ConnectionPool)

Collect open but unused communications to allow opening other ones.
"""
function collect_comms(pool::ConnectionPool)
    available = values(pool.available)
    pool.available = DefaultDict{Address, Set}(Set)

    if !isempty(available)
        info(
            logger,
            "Collecting unused comms.  open: $(pool.num_open), active: $(pool.num_active)"
        )
        for comms in available
            for comm in comms
                close_comm(comm)
            end
        end
        pool.num_open = pool.num_active
    end
end

"""
    Base.close(pool::ConnectionPool)

Close all communications.
"""
function Base.close(pool::ConnectionPool)
    for comms in values(pool.available)
        for comm in comms
            close_comm(comm)
        end
    end
    for comms in values(pool.occupied)
        for comm in comms
            close_comm(comm)
        end
    end
end


##############################          BATCHED SEND          ##############################

"""
    BatchedSend

Batch messages in batches on a stream. Batching several messages at once helps performance
when sending a myriad of tiny messages. Used by both the julia worker and client to
communicate with the scheduler.
"""
type BatchedSend
    interval::AbstractFloat
    please_stop::Bool
    buffer::Array{Dict{String, Any}}
    comm::TCPSocket
    next_deadline::Nullable{AbstractFloat}
end

"""
    BatchedSend(comm::TCPSocket; interval::AbstractFloat=0.002) -> BatchedSend

Batch messages in batches on `comm`. We send lists of messages every `interval`
milliseconds.
"""
function BatchedSend(comm::TCPSocket; interval::AbstractFloat=0.002)
    batchedsend = BatchedSend(
        interval,
        false,
        Array{Dict{String, Any}, 1}(),
        comm,
        nothing
    )
    background_send(batchedsend)
    return batchedsend
end

"""
    background_send(batchedsend::BatchedSend)

Send the messages in `batchsend.buffer` every `interval` milliseconds.
"""
function background_send(batchedsend::BatchedSend)
    @async while !batchedsend.please_stop
        if isempty(batchedsend.buffer)
            batchedsend.next_deadline = nothing
            sleep(batchedsend.interval/2)
            continue
        end

        if isnull(batchedsend.next_deadline) || time() < get(batchedsend.next_deadline)
            continue
        end

        payload, batchedsend.buffer = batchedsend.buffer, Array{Dict{String, Any}, 1}()
        send_msg(batchedsend.comm, payload)
        sleep(batchedsend.interval/2)
    end
end

"""
    send_msg(batchedsend::BatchedSend, msg::Dict{String, Any})

Schedule a message for sending to the other side. This completes quickly and synchronously.
"""
function send_msg(batchedsend::BatchedSend, msg::Dict)
    push!(batchedsend.buffer, msg)
    if isnull(batchedsend.next_deadline)
        batchedsend.next_deadline = time() + batchedsend.interval
    end
end

"""
    Base.close(batchedsend::BatchedSend)

Try to send all remaining messages and then close the connection.
"""
function Base.close(batchedsend::BatchedSend)
    batchedsend.please_stop = true
    if isopen(batchedsend.comm)
        if !isempty(batchedsend.buffer)
            payload, batchedsend.buffer = batchedsend.buffer, Array{Dict{String, Any}, 1}()
            send_msg(batchedsend.comm, payload)
        end
    end
    close(batchedsend.comm)
end
