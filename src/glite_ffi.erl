%% The process plumbing behind a glite connection, for what Gleam's standard
%% library doesn't offer: atomics, ETS, timers, monitors, catching a panic
%% with its stacktrace and re-raising it, and monotonic time. The SQLite
%% calls are in glite_sqlite_ffi; everything else is Gleam.
%%
%% Every call runs in the calling process, holding the connection's lock for
%% as long as it uses the database:
%%
%% - Uncontended, taking the lock is one compare-and-swap on an atomic and
%%   sends no message, so a call costs about as much as calling SQLite
%%   directly.
%% - Under contention, callers queue with the connection's helper process,
%%   which hands the lock to them one at a time, in order. A queued call that
%%   reaches its deadline gives up without running.
%% - A transaction holds the lock from BEGIN to COMMIT, so no other caller's
%%   statement can run in the middle of it.
%%
%% The helper is the one process that can act while the lock's holder is
%% blocked in SQLite. It owns the waiting queue, interrupts a call whose
%% deadline passed, rolls back and frees the lock when its holder dies while
%% holding it, and closes the database when the process that connected
%% crashes. It never runs a query.
-module(glite_ffi).

-export([
    coerce/1, monotonic_ms/0,
    start/2, call/5, disconnect/2, holding/1,
    in_transaction/1, transaction_running/1
]).

%% A connection: the database, its shared state, its helper, and the ETS
%% table where each caller writes its pid before it takes the lock, so the
%% helper can watch the holder.
-record(conn, {db, state, helper, holders, max_queue}).

%% The slots of a connection's state, an atomics array.
%%
%% OWNER is the lock:
%%   ?FREE        nobody holds it;
%%   Id           request Id holds it;
%%   -Id          request Id holds it, its deadline passed, and the helper is
%%                interrupting it;
%%   releasing(Id) request Id is letting go of the lock (see free/2);
%%   ?CLOSED      the database is closed, for good.
%% Ids come from new_id/0: positive, and far below ?RELEASE_OFFSET.
-define(OWNER, 1).
%% The number of callers queued with the helper. Callers only take the lock
%% themselves while it is 0, so they never jump the queue.
-define(QUEUED, 2).
%% The request the helper is interrupting at this moment, or 0. A holder that
%% lets go waits for this to clear (see free/2), so an interrupt can't hit
%% the next holder's statement or a closed database.
-define(INTERRUPTING, 3).

-define(FREE, 0).
-define(RELEASE_OFFSET, 16#4000000000000000).
-define(CLOSED, -16#7FFFFFFFFFFFFFFF).

%% Callers queue only while QUEUED > 0. A closing connection adds this to it
%% so that every new call goes to the helper, which refuses it.
-define(CLOSING_WEIGHT, 16#100000000).

-define(INTERRUPT_EVERY_MS, 10).
-define(ROLLBACK_TRIES, 50).
-define(SQLITE_INTERRUPT, 9).
-define(INTERRUPT_STUCK_MS, 5000).

coerce(X) -> X.

monotonic_ms() -> erlang:monotonic_time(millisecond).

new_id() -> erlang:unique_integer([positive, monotonic]).

releasing(Id) -> -(Id + ?RELEASE_OFFSET).

%% The request an OWNER value belongs to, or none.
owner_id(?FREE) -> none;
owner_id(?CLOSED) -> none;
owner_id(Owner) when Owner > 0 -> Owner;
owner_id(Owner) when Owner > -?RELEASE_OFFSET -> -Owner;
owner_id(Owner) -> -Owner - ?RELEASE_OFFSET.

%% =============================================================================
%% Connecting
%% =============================================================================

%% Start the helper for an open database, linked to the caller like any
%% process that holds a resource for it.
start(Db, MaxQueue) ->
    State = atomics:new(3, [{signed, true}]),
    Creator = self(),
    Helper = spawn_link(fun() -> helper_init(Creator, Db, State) end),
    glite_sqlite_ffi:give_away(Db, Helper),
    receive
        {glite_started, Helper, Holders} ->
            #conn{db = Db, state = State, helper = Helper,
                  holders = Holders, max_queue = MaxQueue}
    end.

%% Whether the calling process holds this connection's lock: it is inside one
%% of its transactions.
holding(#conn{state = State}) ->
    get({glite_holding, State}) =:= true.

%% Run Body(Token) as a transaction of the calling process. Until Body
%% returns or raises, transaction_running(Token) is true in this process and
%% nowhere else, so a Tx can tell whether it is still inside its transaction:
%% one that was kept after it ended, or sent to another process, would run
%% its statements without holding the connection.
in_transaction(Body) ->
    Token = make_ref(),
    put({glite_transaction, Token}, true),
    try
        Body(Token)
    after
        erase({glite_transaction, Token})
    end.

transaction_running(Token) ->
    get({glite_transaction, Token}) =:= true.

%% =============================================================================
%% Calls
%% =============================================================================

%% Take the lock, run Job(Deadline) in the calling process, and let go.
%%
%% If the deadline passes while the job runs, the helper interrupts SQLite
%% until the job lets go of the lock. A job that still returned Ok committed
%% and is reported as Ok; one that failed is reported as a timeout.
%%
%% If Job raises, Cleanup rolls back whatever it left open, and the exception
%% is re-raised here with its stacktrace. If Cleanup itself raises, the
%% connection can't be trusted any more: it is closed, then that is raised.
%%
%% Wrap shapes glite's own errors: plain gives {error, E}; in_transaction gives
%% {error, {database, E}}, glite's TransactionError.
call(Conn, Timeout, Wrap, Job, Cleanup) ->
    Id = new_id(),
    Deadline = monotonic_ms() + Timeout,
    case enter(Conn, Id, Deadline, Timeout) of
        acquired -> run(Conn, Id, Deadline, Timeout, Wrap, Job, Cleanup);
        {refused, Error} -> wrap_error(Error, Wrap)
    end.

run(#conn{state = State, helper = Helper} = Conn, Id, Deadline, Timeout, Wrap, Job, Cleanup) ->
    Timer = erlang:start_timer(Deadline, Helper, {glite_deadline, Id}, [{abs, true}]),
    put({glite_holding, State}, true),
    Outcome =
        try
            {done, Job(Deadline)}
        catch
            Class:Reason:Stacktrace ->
                {panicked, Class, Reason, Stacktrace}
        end,
    Settled =
        case Outcome of
            {done, _} ->
                Outcome;
            {panicked, _, _, _} ->
                try
                    Cleanup(),
                    Outcome
                catch
                    C2:R2:S2 -> {poisoned, C2, R2, S2}
                end
        end,
    erase({glite_holding, State}),
    _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
    case Settled of
        {poisoned, Class3, Reason3, Stacktrace3} ->
            poison(Conn, Id),
            erlang:raise(Class3, Reason3, Stacktrace3);
        _ ->
            Cancelled = free(Conn, Id),
            case Settled of
                {panicked, Class4, Reason4, Stacktrace4} ->
                    erlang:raise(Class4, Reason4, Stacktrace4);
                {done, {error, _}} when Cancelled ->
                    wrap_error({timeout, Timeout}, Wrap);
                {done, Result} ->
                    Result
            end
    end.

%% Close the database and stop the helper. Waits for the lock like any call,
%% so a running transaction finishes first.
disconnect(#conn{db = Db, state = State, helper = Helper} = Conn, Timeout) ->
    Id = new_id(),
    case enter(Conn, Id, monotonic_ms() + Timeout, Timeout) of
        {refused, connection_closed} ->
            {ok, nil};
        {refused, Error} ->
            {error, Error};
        acquired ->
            %% No deadline timer was started, so the helper can't be
            %% interrupting this request: OWNER is still Id.
            ok = atomics:compare_exchange(State, ?OWNER, Id, ?CLOSED),
            glite_sqlite_ffi:close(Db),
            Helper ! glite_closed,
            {ok, nil}
    end.

%% =============================================================================
%% The lock
%% =============================================================================

%% Register the caller as a possible holder, then take the lock or queue for
%% it. The helper's ETS table goes with the helper, so a missing table means
%% the connection is closed.
enter(#conn{holders = Holders} = Conn, Id, Deadline, Timeout) ->
    try ets:insert(Holders, {Id, self()}) of
        true ->
            case acquire(Conn, Id, Deadline, Timeout) of
                acquired ->
                    acquired;
                {refused, _} = Refused ->
                    forget(Holders, Id),
                    Refused
            end
    catch
        error:badarg -> {refused, connection_closed}
    end.

acquire(#conn{state = State} = Conn, Id, Deadline, Timeout) ->
    case atomics:get(State, ?QUEUED) of
        0 ->
            case atomics:compare_exchange(State, ?OWNER, ?FREE, Id) of
                ok -> acquired;
                ?CLOSED -> {refused, connection_closed};
                _ -> queue(Conn, Id, Deadline, Timeout)
            end;
        _ ->
            queue(Conn, Id, Deadline, Timeout)
    end.

%% Wait in the helper's queue until it hands over the lock, or the deadline
%% passes. A call that gave up never runs: if the lock arrives just as it
%% gives up, it lets go straight away.
queue(#conn{state = State, helper = Helper, max_queue = MaxQueue} = Conn, Id, Deadline, Timeout) ->
    case atomics:add_get(State, ?QUEUED, 1) of
        N when N > MaxQueue, N < ?CLOSING_WEIGHT ->
            atomics:sub(State, ?QUEUED, 1),
            {refused, {overloaded, MaxQueue}};
        _ ->
            Monitor = erlang:monitor(process, Helper),
            Helper ! {glite_wait, Id, self()},
            receive
                {glite_granted, Id} ->
                    erlang:demonitor(Monitor, [flush]),
                    acquired;
                {glite_closed, Id} ->
                    erlang:demonitor(Monitor, [flush]),
                    {refused, connection_closed};
                {'DOWN', Monitor, process, _, _} ->
                    {refused, connection_closed}
            after max(0, Deadline - monotonic_ms()) ->
                Helper ! {glite_cancel, Id},
                receive
                    {glite_granted, Id} ->
                        erlang:demonitor(Monitor, [flush]),
                        _ = free(Conn, Id),
                        {refused, {timeout, Timeout}};
                    {glite_cancelled, Id} ->
                        erlang:demonitor(Monitor, [flush]),
                        {refused, {timeout, Timeout}};
                    {glite_closed, Id} ->
                        erlang:demonitor(Monitor, [flush]),
                        {refused, connection_closed};
                    {'DOWN', Monitor, process, _, _} ->
                        {refused, connection_closed}
                end
            end
    end.

%% Let go of the lock, and say whether the helper interrupted this request.
%%
%% An interrupted request first moves OWNER to releasing(Id) and waits until no
%% interrupt for it is in flight, and only then frees the lock, so the next
%% holder can't be hit by an interrupt meant for this one.
free(#conn{state = State, holders = Holders, helper = Helper}, Id) ->
    Cancelled =
        case atomics:compare_exchange(State, ?OWNER, Id, ?FREE) of
            ok ->
                false;
            _ ->
                ok = atomics:compare_exchange(State, ?OWNER, -Id, releasing(Id)),
                wait_for_interrupt(State, Id, monotonic_ms() + ?INTERRUPT_STUCK_MS),
                ok = atomics:compare_exchange(State, ?OWNER, releasing(Id), ?FREE),
                true
        end,
    forget(Holders, Id),
    case atomics:get(State, ?QUEUED) of
        0 -> ok;
        _ -> Helper ! glite_release
    end,
    Cancelled.

wait_for_interrupt(State, Id, Until) ->
    case atomics:get(State, ?INTERRUPTING) of
        Id ->
            case monotonic_ms() > Until of
                true -> erlang:error({glite_interrupt_stuck, Id});
                false ->
                    erlang:yield(),
                    wait_for_interrupt(State, Id, Until)
            end;
        _ ->
            ok
    end.

%% A job's cleanup failed, so the database may still be inside a
%% transaction. Close it rather than hand it to the next caller.
poison(#conn{db = Db, state = State, helper = Helper} = Conn, Id) ->
    case atomics:compare_exchange(State, ?OWNER, Id, ?CLOSED) of
        ok ->
            ok;
        _ ->
            ok = atomics:compare_exchange(State, ?OWNER, -Id, releasing(Id)),
            wait_for_interrupt(State, Id, monotonic_ms() + ?INTERRUPT_STUCK_MS),
            ok = atomics:compare_exchange(State, ?OWNER, releasing(Id), ?CLOSED)
    end,
    glite_sqlite_ffi:close(Db),
    forget(Conn#conn.holders, Id),
    Helper ! glite_closed,
    ok.

forget(Holders, Id) ->
    try ets:delete(Holders, Id) of
        true -> ok
    catch
        error:badarg -> ok
    end.

wrap_error(Error, plain) -> {error, Error};
wrap_error(Error, in_transaction) -> {error, {database, Error}}.

%% =============================================================================
%% The helper
%% =============================================================================

-record(helper, {
    creator,
    db,
    state,
    holders,
    %% Callers waiting for the lock, oldest first: {Id, Pid}.
    waiting = queue:new(),
    %% The holder being watched: {Id, MonitorRef}, or none.
    watching = none,
    closing = false
}).

helper_init(Creator, Db, State) ->
    process_flag(trap_exit, true),
    Holders = ets:new(glite_holders, [set, public, {write_concurrency, true}]),
    Creator ! {glite_started, self(), Holders},
    helper_loop(#helper{creator = Creator, db = Db, state = State, holders = Holders}).

helper_loop(#helper{state = State} = H) ->
    receive
        {glite_wait, Id, Pid} when H#helper.closing ->
            atomics:sub(State, ?QUEUED, 1),
            Pid ! {glite_closed, Id},
            helper_loop(H);
        {glite_wait, Id, Pid} ->
            Waiting = queue:in({Id, Pid}, H#helper.waiting),
            grant(H#helper{waiting = Waiting});
        {glite_cancel, Id} ->
            case take(Id, H#helper.waiting) of
                {ok, Pid, Rest} ->
                    atomics:sub(State, ?QUEUED, 1),
                    Pid ! {glite_cancelled, Id},
                    helper_loop(H#helper{waiting = Rest});
                none ->
                    %% Already granted: the caller lets go when it sees that.
                    helper_loop(H)
            end;
        glite_release ->
            grant(H);
        {timeout, _Timer, {glite_deadline, Id}} ->
            case atomics:compare_exchange(State, ?OWNER, Id, -Id) of
                ok ->
                    interrupt_request(H, Id),
                    erlang:send_after(?INTERRUPT_EVERY_MS, self(), {glite_reinterrupt, Id}),
                    helper_loop(watch(H, Id));
                _ ->
                    %% The request let go of the lock in time.
                    helper_loop(H)
            end;
        {glite_reinterrupt, Id} ->
            %% One interrupt is not enough: SQLite only interrupts the
            %% statements running at that moment, so an interrupt that lands
            %% between two statements of a transaction is lost. Keep going
            %% until the request lets go of the lock.
            case atomics:get(State, ?OWNER) =:= -Id of
                true ->
                    interrupt_request(H, Id),
                    erlang:send_after(?INTERRUPT_EVERY_MS, self(), {glite_reinterrupt, Id});
                false ->
                    ok
            end,
            helper_loop(H);
        {'DOWN', Ref, process, _, _} ->
            case H#helper.watching of
                {Id, Ref} -> holder_died(H#helper{watching = none}, Id);
                _ -> helper_loop(H)
            end;
        {'EXIT', Creator, normal} when Creator =:= H#helper.creator ->
            %% Like any linked process, the connection outlives a creator
            %% that exits normally.
            helper_loop(H);
        {'EXIT', Creator, _} when Creator =:= H#helper.creator ->
            close_down(H);
        {'EXIT', _, normal} ->
            helper_loop(H);
        {'EXIT', _, Reason} ->
            %% A recovery crashed, so the lock may never be freed. Callers
            %% see the helper die and get ConnectionClosed.
            exit(Reason);
        glite_closed ->
            %% disconnect/2, poison/2 or recover/4 closed the database.
            stop(H);
        {'ETS-TRANSFER', _, _, glite_statements} ->
            helper_loop(H)
    end.

%% Hand the lock to the oldest waiter, if it is free.
grant(#helper{state = State, waiting = Waiting} = H) ->
    case queue:out(Waiting) of
        {empty, _} when H#helper.closing ->
            try_close(H);
        {empty, _} ->
            helper_loop(H);
        {{value, {Id, Pid}}, Rest} ->
            case atomics:compare_exchange(State, ?OWNER, ?FREE, Id) of
                ok ->
                    atomics:sub(State, ?QUEUED, 1),
                    Pid ! {glite_granted, Id},
                    helper_loop(watch_pid(H#helper{waiting = Rest}, Id, Pid));
                ?CLOSED ->
                    stop(H);
                Owner ->
                    %% Busy: its holder sends glite_release when it lets go.
                    %% Watch it, in case it dies holding the lock.
                    helper_loop(watch(H, owner_id(Owner)))
            end
    end.

%% Watch the lock's current holder, request Id, so that if it dies holding
%% the lock, the helper takes the lock back.
watch(H, none) ->
    H;
watch(#helper{watching = {Id, _}} = H, Id) ->
    H;
watch(#helper{holders = Holders} = H, Id) ->
    case ets:lookup(Holders, Id) of
        [{Id, Pid}] -> watch_pid(H, Id, Pid);
        %% It let go of the lock already.
        [] -> H
    end.

watch_pid(H, Id, Pid) ->
    case H#helper.watching of
        {_, Old} -> erlang:demonitor(Old, [flush]);
        none -> ok
    end,
    H#helper{watching = {Id, erlang:monitor(process, Pid)}}.

%% A watched holder died. If it still held the lock, in any of its states,
%% nothing else can free it, so the helper takes the lock back and starts a
%% recovery (see recover/4). If it had let go already, it may have died
%% before telling the helper, so the queue is served either way.
holder_died(#helper{db = Db, state = State, holders = Holders} = H, Id) ->
    Owner = atomics:get(State, ?OWNER),
    case owner_id(Owner) =:= Id andalso
         atomics:compare_exchange(State, ?OWNER, Owner, releasing(Id)) =:= ok of
        false ->
            grant(H);
        true ->
            forget(Holders, Id),
            Helper = self(),
            _ = spawn_link(fun() -> recover(Db, State, Id, Helper) end),
            helper_loop(H)
    end.

%% Roll back what a dead holder left open, then free the lock, or close the
%% database if it can't be rolled back.
%%
%% A process killed inside a dirty NIF is reported dead before the NIF
%% returns, so the dead holder's statement may still be running and holding
%% SQLite's connection mutex. This runs in its own process, so the helper
%% keeps serving its queue meanwhile, and interrupts the connection until the
%% rollback is done, so a long statement can't hold up the recovery. Only
%% this process and the dead statement use the database until it frees the
%% lock, and it stops the interrupter first, so no interrupt can reach the
%% next holder.
recover(Db, State, Id, Helper) ->
    Interrupter = spawn_link(fun() -> keep_interrupting(Db) end),
    %% sqlite3_exec takes the connection mutex, so this returns only once
    %% the dead statement has.
    _ = glite_sqlite_ffi:exec_script(Db, <<"">>),
    %% It may have left a cached statement half way through a query.
    glite_sqlite_ffi:clear_statements(Db),
    Result = rollback(Db, ?ROLLBACK_TRIES),
    Ref = erlang:monitor(process, Interrupter),
    Interrupter ! glite_stop,
    receive {'DOWN', Ref, process, Interrupter, _} -> ok end,
    case Result of
        ok ->
            ok = atomics:compare_exchange(State, ?OWNER, releasing(Id), ?FREE),
            Helper ! glite_release;
        error ->
            ok = atomics:compare_exchange(State, ?OWNER, releasing(Id), ?CLOSED),
            glite_sqlite_ffi:close(Db),
            Helper ! glite_closed
    end.

keep_interrupting(Db) ->
    glite_sqlite_ffi:interrupt(Db),
    receive
        glite_stop -> ok
    after ?INTERRUPT_EVERY_MS ->
        keep_interrupting(Db)
    end.

%% An interrupt that lands just as ROLLBACK starts aborts it, so an
%% interrupted ROLLBACK is tried again.
rollback(_Db, 0) ->
    error;
rollback(Db, Tries) ->
    case glite_sqlite_ffi:autocommit(Db) of
        true ->
            ok;
        false ->
            case glite_sqlite_ffi:exec_script(Db, <<"ROLLBACK">>) of
                {ok, nil} -> ok;
                {error, {sqlite_failure, Code, _, _}} when Code band 16#FF =:= ?SQLITE_INTERRUPT ->
                    rollback(Db, Tries - 1);
                {error, _} -> error
            end
    end.

%% The process that connected crashed: refuse new calls, let the running one
%% finish, then close the database.
close_down(#helper{state = State, waiting = Waiting} = H) ->
    atomics:add(State, ?QUEUED, ?CLOSING_WEIGHT),
    refuse_all(State, Waiting),
    try_close(H#helper{waiting = queue:new(), closing = true}).

try_close(#helper{db = Db, state = State} = H) ->
    case atomics:compare_exchange(State, ?OWNER, ?FREE, ?CLOSED) of
        ok ->
            glite_sqlite_ffi:close(Db),
            stop(H);
        ?CLOSED ->
            stop(H);
        Owner ->
            helper_loop(watch(H, owner_id(Owner)))
    end.

stop(#helper{state = State, waiting = Waiting, creator = Creator}) ->
    refuse_all(State, Waiting),
    unlink(Creator),
    exit(normal).

refuse_all(State, Waiting) ->
    lists:foreach(
        fun({Id, Pid}) ->
            atomics:sub(State, ?QUEUED, 1),
            Pid ! {glite_closed, Id}
        end,
        queue:to_list(Waiting)
    ).

take(Id, Waiting) ->
    case lists:keytake(Id, 1, queue:to_list(Waiting)) of
        {value, {Id, Pid}, Rest} -> {ok, Pid, queue:from_list(Rest)};
        false -> none
    end.

%% Interrupt the connection if request Id still holds the lock and is being
%% cancelled. INTERRUPTING marks the call as in flight; a holder that lets
%% go moves OWNER away from -Id before it reads INTERRUPTING (see free/2), and
%% this reads OWNER after it sets INTERRUPTING, so either the holder waits for
%% this interrupt or this sees the request let go and doesn't interrupt.
interrupt_request(#helper{db = Db, state = State}, Id) ->
    ok = atomics:compare_exchange(State, ?INTERRUPTING, 0, Id),
    case atomics:get(State, ?OWNER) =:= -Id of
        true -> glite_sqlite_ffi:interrupt(Db);
        false -> nil
    end,
    atomics:put(State, ?INTERRUPTING, 0),
    ok.
