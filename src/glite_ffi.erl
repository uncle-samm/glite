%% The process plumbing behind glite's connection actor, for what Gleam's
%% libraries don't offer: shared atomic counters, monitors that double as
%% reply aliases (so a late reply is dropped), catching a panic with its
%% stacktrace and re-raising it, persistent_term, and monotonic time. The
%% SQLite calls are in glite_sqlite_ffi; everything else is Gleam.
-module(glite_ffi).

-export([
    protect/1, coerce/1,
    new_counters/0, admit/2, dequeued/1, begin_request/3, end_request/2,
    prepare_call/1, reply/2, await/7,
    monotonic_ms/0, unique_id/0,
    put_named/2, get_named/1, erase_named/1
]).

-define(INTERRUPT_EVERY_MS, 10).
-define(INTERRUPT_STUCK_MS, 5000).

%% =============================================================================
%% Actor plumbing
%% =============================================================================

%% Run a job, turning an exception into a value so the actor survives it and
%% can hand it back to the caller, which re-raises it.
protect(Fun) ->
    try
        {done, Fun()}
    catch
        Class:Reason:Stacktrace -> {panicked, Class, Reason, Stacktrace}
    end.

coerce(X) -> X.

monotonic_ms() -> erlang:monotonic_time(millisecond).

unique_id() -> erlang:unique_integer([positive, monotonic]).

%% Three shared counters per connection:
%%   1. the id of the request the actor is running: 0 when idle, Id while
%%      running it, -Id once a caller has given up on it;
%%   2. the number of requests sent but not yet taken by the actor;
%%   3. the id of the request a canceller is interrupting at this moment, or
%%      0. The actor waits for this to clear before it moves on (see
%%      end_request), so an interrupt can't hit the next request.
new_counters() -> atomics:new(3, [{signed, true}]).

%% Count a request in, or refuse it when the queue is full.
admit(Counters, MaxQueue) ->
    case atomics:add_get(Counters, 2, 1) of
        N when N > MaxQueue ->
            atomics:sub(Counters, 2, 1),
            {error, {overloaded, MaxQueue}};
        _ ->
            {ok, nil}
    end.

dequeued(Counters) ->
    atomics:sub(Counters, 2, 1),
    nil.

%% Mark a request as running, unless its caller's deadline has passed: then
%% the caller has already returned Timeout, and the request must not run.
begin_request(Counters, Id, Deadline) ->
    atomics:put(Counters, 1, Id),
    case monotonic_ms() >= Deadline of
        true ->
            end_request(Counters, Id),
            expired;
        false ->
            started
    end.

%% Mark the actor idle. If a caller gave up on this request, a canceller may
%% be interrupting it: take the request back, then wait for an interrupt call
%% that is still in flight, so it can't hit the next request.
end_request(Counters, Id) ->
    case atomics:compare_exchange(Counters, 1, Id, 0) of
        ok ->
            nil;
        _ ->
            ok = atomics:compare_exchange(Counters, 1, -Id, 0),
            wait_for_interrupt(Counters, Id, monotonic_ms() + ?INTERRUPT_STUCK_MS)
    end.

wait_for_interrupt(Counters, Id, Until) ->
    case atomics:get(Counters, 3) of
        Id ->
            case monotonic_ms() > Until of
                true -> erlang:error({glite_interrupt_stuck, Id});
                false ->
                    erlang:yield(),
                    wait_for_interrupt(Counters, Id, Until)
            end;
        _ ->
            nil
    end.

%% Set up a call to the actor: a monitor whose reference is also an alias, so
%% a reply that arrives after the caller gave up is dropped by the runtime.
prepare_call(Pid) ->
    erlang:monitor(process, Pid, [{alias, demonitor}]).

reply(Alias, Outcome) ->
    erlang:send(Alias, {glite_reply, Alias, Outcome}),
    nil.

%% Wait for the actor's reply.
%%
%% On timeout the caller cancels. If the actor is running this request, a
%% canceller process interrupts it (see cancel/5) while the caller waits up to
%% Grace ms for the outcome: a request that still committed is reported as
%% committed, one that failed is reported as a timeout. If the actor has not
%% started the request it never will (see begin_request), so that timeout
%% means nothing was written.
%%
%% The caller never calls the interrupt NIF itself, so it can't be held up by
%% it: the call returns within Timeout + Grace ms whatever happens.
%%
%% Wrap shapes glite's own errors: plain gives {error, E}; in_transaction gives
%% {error, {database, E}}, glite's TransactionError.
await(Mref, Id, Db, Counters, Timeout, Grace, Wrap) ->
    receive
        {glite_reply, Mref, Outcome} ->
            erlang:demonitor(Mref, [flush]),
            unwrap(Outcome, false, Timeout, Wrap);
        {'DOWN', Mref, process, _, _} ->
            wrap_error(connection_closed, Wrap)
    after Timeout ->
        case atomics:compare_exchange(Counters, 1, Id, -Id) of
            ok ->
                Until = monotonic_ms() + Grace,
                Caller = self(),
                Canceller = spawn(fun() -> cancel(Caller, Db, Counters, Id, Until) end),
                Result =
                    receive
                        {glite_reply, Mref, Outcome} ->
                            erlang:demonitor(Mref, [flush]),
                            unwrap(Outcome, true, Timeout, Wrap);
                        {'DOWN', Mref, process, _, _} ->
                            wrap_error(connection_closed, Wrap)
                    after Grace ->
                        erlang:demonitor(Mref, [flush]),
                        flush_reply(Mref),
                        wrap_error({timeout, Timeout}, Wrap)
                    end,
                Canceller ! glite_stop,
                Result;
            _ ->
                %% Not started yet, or already finished. A finished request
                %% replied before marking itself done, so its reply is here.
                erlang:demonitor(Mref, [flush]),
                receive
                    {glite_reply, Mref, Outcome} -> unwrap(Outcome, false, Timeout, Wrap)
                after 0 ->
                    wrap_error({timeout, Timeout}, Wrap)
                end
        end
    end.

%% Interrupt request Id until the actor is done with it, the caller stops
%% waiting for it (it got the reply, gave up, or died), or Until passes.
%%
%% One interrupt is not enough: SQLite only interrupts the statements running
%% at that moment, so an interrupt that lands between two statements of a
%% transaction, or just before a statement starts, is lost.
cancel(Caller, Db, Counters, Id, Until) ->
    Ref = erlang:monitor(process, Caller),
    cancel_loop(Ref, Db, Counters, Id, Until),
    nil.

cancel_loop(Ref, Db, Counters, Id, Until) ->
    case interrupt_request(Db, Counters, Id) of
        finished ->
            done;
        _ ->
            Wait = min(?INTERRUPT_EVERY_MS, max(0, Until - monotonic_ms())),
            receive
                glite_stop -> done;
                {'DOWN', Ref, process, _, _} -> done
            after Wait ->
                case monotonic_ms() >= Until of
                    true -> done;
                    false -> cancel_loop(Ref, Db, Counters, Id, Until)
                end
            end
    end.

%% Interrupt the connection if the actor is still on request Id. Counter 3
%% marks the call as in flight; the actor clears counter 1 before it reads
%% counter 3 (see end_request), and this reads counter 1 after it sets counter
%% 3, so either the actor waits for this interrupt or this sees the request is
%% finished and doesn't interrupt.
interrupt_request(Db, Counters, Id) ->
    case atomics:compare_exchange(Counters, 3, 0, Id) of
        ok ->
            Result =
                case atomics:get(Counters, 1) =:= -Id of
                    true ->
                        glite_sqlite_ffi:interrupt(Db),
                        interrupted;
                    false ->
                        finished
                end,
            atomics:put(Counters, 3, 0),
            Result;
        _ ->
            %% Another canceller, for an earlier request, holds counter 3 for
            %% a moment. Try again on the next round.
            busy
    end.

flush_reply(Mref) ->
    receive {glite_reply, Mref, _} -> ok after 0 -> ok end.

unwrap(never_ran, _Cancelled, Timeout, Wrap) ->
    wrap_error({timeout, Timeout}, Wrap);
unwrap({panicked, Class, Reason, Stacktrace}, _Cancelled, _Timeout, _Wrap) ->
    erlang:raise(Class, Reason, Stacktrace);
unwrap({done, {error, _}}, true, Timeout, Wrap) ->
    wrap_error({timeout, Timeout}, Wrap);
unwrap({done, Result}, _Cancelled, _Timeout, _Wrap) ->
    Result.

wrap_error(Error, plain) -> {error, Error};
wrap_error(Error, in_transaction) -> {error, {database, Error}}.

%% A supervised connection publishes its handle under its name, so callers
%% that only know the name reach the current actor after a restart.
put_named(Name, Handle) ->
    persistent_term:put({glite_handle, Name}, Handle),
    nil.

get_named(Name) ->
    case persistent_term:get({glite_handle, Name}, undefined) of
        undefined -> {error, nil};
        Handle -> {ok, Handle}
    end.

erase_named(Name) ->
    _ = persistent_term:erase({glite_handle, Name}),
    nil.
