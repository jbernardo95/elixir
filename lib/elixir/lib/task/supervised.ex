defmodule Task.Supervised do
  @moduledoc false
  @ref_timeout 5_000

  def start(info, fun) do
    {:ok, :proc_lib.spawn(__MODULE__, :noreply, [info, fun])}
  end

  def start_link(info, fun) do
    {:ok, :proc_lib.spawn_link(__MODULE__, :noreply, [info, fun])}
  end

  def start_link(caller, link, info, fun) do
    {:ok, spawn_link(caller, link, info, fun)}
  end

  def spawn_link(caller, link \\ :nolink, info, fun) do
    :proc_lib.spawn_link(__MODULE__, :reply, [caller, link, info, fun])
  end

  def reply(caller, link, info, mfa) do
    initial_call(mfa)
    case link do
      :link ->
        try do
          Process.link(caller)
        catch
          :error, :noproc ->
            exit({:shutdown, :noproc})
        end
        reply(caller, nil, @ref_timeout, info, mfa)
      :monitor ->
        mref = Process.monitor(caller)
        reply(caller, mref, @ref_timeout, info, mfa)
      :nolink ->
        reply(caller, nil, :infinity, info, mfa)
    end
  end

  defp reply(caller, mref, timeout, info, mfa) do
    receive do
      {^caller, ref} ->
        _ = if mref, do: Process.demonitor(mref, [:flush])
        send caller, {ref, do_apply(info, mfa)}
      {:DOWN, ^mref, _, _, reason} when is_reference(mref) ->
        exit({:shutdown, reason})
    after
      # There is a race condition on this operation when working across
      # node that manifests if a "Task.Supervisor.async/2" call is made
      # while the supervisor is busy spawning previous tasks.
      #
      # Imagine the following workflow:
      #
      # 1. The nodes disconnect
      # 2. The async call fails and is caught, the calling process does not exit
      # 3. The task is spawned and links to the calling process, causing the nodes to reconnect
      # 4. The calling process has not exited and so does not send its monitor reference
      # 5. The spawned task waits forever for the monitor reference so it can begin
      #
      # We have solved this by specifying a timeout of 5000 seconds.
      # Given no work is done in the client between the task start and
      # sending the reference, 5000 should be enough to not raise false
      # negatives unless the nodes are indeed not available.
      #
      # The same situation could occur with "Task.Supervisor.async_nolink/2",
      # except a monitor is used instead of a link.
      timeout ->
        exit(:timeout)
    end
  end

  def noreply(info, mfa) do
    initial_call(mfa)
    do_apply(info, mfa)
  end

  defp initial_call(mfa) do
    Process.put(:"$initial_call", get_initial_call(mfa))
  end

  defp get_initial_call({:erlang, :apply, [fun, []]}) when is_function(fun, 0) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {module, name, 0}
  end

  defp get_initial_call({mod, fun, args}) do
    {mod, fun, length(args)}
  end

  defp do_apply(info, {module, fun, args} = mfa) do
    try do
      apply(module, fun, args)
    catch
      :error, value ->
        reason = {value, System.stacktrace()}
        exit(info, mfa, reason, reason)
      :throw, value ->
        reason = {{:nocatch, value}, System.stacktrace()}
        exit(info, mfa, reason, reason)
      :exit, value ->
        exit(info, mfa, {value, System.stacktrace()}, value)
    end
  end

  defp exit(_info, _mfa, _log_reason, reason)
       when reason == :normal
       when reason == :shutdown
       when tuple_size(reason) == 2 and elem(reason, 0) == :shutdown do
    exit(reason)
  end

  defp exit(info, mfa, log_reason, reason) do
    {fun, args} = get_running(mfa)

    :error_logger.format(
      '** Task ~p terminating~n' ++
      '** Started from ~p~n' ++
      '** When function  == ~p~n' ++
      '**      arguments == ~p~n' ++
      '** Reason for termination == ~n' ++
      '** ~p~n', [self(), get_from(info), fun, args, get_reason(log_reason)])

    exit(reason)
  end

  defp get_from({node, pid_or_name}) when node == node(), do: pid_or_name
  defp get_from(other), do: other

  defp get_running({:erlang, :apply, [fun, []]}) when is_function(fun, 0), do: {fun, []}
  defp get_running({mod, fun, args}), do: {:erlang.make_fun(mod, fun, length(args)), args}

  defp get_reason({:undef, [{mod, fun, args, _info} | _] = stacktrace} = reason)
       when is_atom(mod) and is_atom(fun) do
    cond do
      :code.is_loaded(mod) === false ->
        {:"module could not be loaded", stacktrace}
      is_list(args) and not function_exported?(mod, fun, length(args)) ->
        {:"function not exported", stacktrace}
      is_integer(args) and not function_exported?(mod, fun, args) ->
        {:"function not exported", stacktrace}
      true ->
        reason
    end
  end

  defp get_reason(reason) do
    reason
  end

  ## Stream

  def stream(enumerable, acc, reducer, mfa, options, spawn) do
    next = &Enumerable.reduce(enumerable, &1, fn x, acc -> {:suspend, [x | acc]} end)
    max_concurrency = Keyword.get(options, :max_concurrency, System.schedulers_online)
    timeout = Keyword.get(options, :timeout, 5000)
    parent = self()

    # Start a process responsible for translating down messages.
    {monitor_pid, monitor_ref} = spawn_monitor(fn -> stream_monitor(parent) end)
    send(monitor_pid, {parent, monitor_ref})

    stream_reduce(acc, max_concurrency, 0, 0, %{}, next,
                  reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
  end

  defp stream_reduce({:halt, acc}, _max, _spawned, _delivered, waiting, next,
                     _reducer, _mfa, _spawn, monitor_pid, monitor_ref, timeout) do
    is_function(next) && next.({:halt, []})
    stream_close(waiting, monitor_pid, monitor_ref, timeout)
    {:halted, acc}
  end

  defp stream_reduce({:suspend, acc}, max, spawned, delivered, waiting, next,
                     reducer, mfa, spawn, monitor_pid, monitor_ref, timeout) do
    {:suspended, acc, &stream_reduce(&1, max, spawned, delivered, waiting, next,
                                     reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)}
  end

  # All spawned, all delivered, next is done.
  defp stream_reduce({:cont, acc}, _max, spawned, delivered, waiting, next,
                     _reducer, _mfa, _spawn, monitor_pid, monitor_ref, timeout)
       when spawned == delivered and next == :done do
    stream_close(waiting, monitor_pid, monitor_ref, timeout)
    {:done, acc}
  end

  # No more tasks to spawn because max == 0 or next is done.
  defp stream_reduce({:cont, acc}, max, spawned, delivered, waiting, next,
                     reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
       when max == 0
       when next == :done do
    receive do
      {{^monitor_ref, position}, value} ->
        %{^position => {pid, :running}} = waiting
        waiting = Map.put(waiting, position, {pid, {:ok, value}})
        stream_reduce({:cont, acc}, max, spawned, delivered, waiting, next,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
      {:DOWN, {^monitor_ref, position}, reason} ->
        waiting =
          case waiting do
            # We update the entry only if it is running.
            # If it is ok or removed, we are done.
            %{^position => {pid, :running}} -> Map.put(waiting, position, {pid, {:exit, reason}})
            %{} -> waiting
          end
        stream_deliver({:cont, acc}, max + 1, spawned, delivered, waiting, next,
                       reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
      {:DOWN, ^monitor_ref, _, ^monitor_pid, reason} ->
        stream_close(waiting, monitor_pid, monitor_ref, timeout)
        exit({reason, {__MODULE__, :stream, [timeout]}})
    after
      timeout ->
        stream_close(waiting, monitor_pid, monitor_ref, timeout)
        exit({:timeout, {__MODULE__, :stream, [timeout]}})
    end
  end

  defp stream_reduce({:cont, acc}, max, spawned, delivered, waiting, next,
                     reducer, mfa, spawn, monitor_pid, monitor_ref, timeout) do
    try do
      next.({:cont, []})
    catch
      kind, reason ->
        stacktrace = System.stacktrace
        stream_close(waiting, monitor_pid, monitor_ref, timeout)
        :erlang.raise(kind, reason, stacktrace)
    else
      {:suspended, [value], next} ->
        waiting = stream_spawn(value, spawned, waiting, mfa, spawn, monitor_pid, monitor_ref)
        stream_reduce({:cont, acc}, max - 1, spawned + 1, delivered, waiting, next,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
      {_, [value]} ->
        waiting = stream_spawn(value, spawned, waiting, mfa, spawn, monitor_pid, monitor_ref)
        stream_reduce({:cont, acc}, max - 1, spawned + 1, delivered, waiting, :done,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
      {_, []} ->
        stream_reduce({:cont, acc}, max, spawned, delivered, waiting, :done,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
    end
  end

  defp stream_deliver({:suspend, acc}, max, spawned, delivered, waiting, next,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout) do
    {:suspended, acc, &stream_deliver(&1, max, spawned, delivered, waiting, next,
                                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)}
  end
  defp stream_deliver({:halt, acc}, max, spawned, delivered, waiting, next,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout) do
    stream_reduce({:halt, acc}, max, spawned, delivered, waiting, next,
                  reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
  end
  defp stream_deliver({:cont, acc}, max, spawned, delivered, waiting, next,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout) do
    case waiting do
      %{^delivered => {_, {_, _} = reply}} ->
        try do
          reducer.(reply, acc)
        catch
          kind, reason ->
            stacktrace = System.stacktrace
            is_function(next) && next.({:halt, []})
            stream_close(waiting, monitor_pid, monitor_ref, timeout)
            :erlang.raise(kind, reason, stacktrace)
        else
          pair ->
            stream_deliver(pair, max, spawned, delivered + 1, Map.delete(waiting, delivered), next,
                           reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
        end
      %{} ->
        stream_reduce({:cont, acc}, max, spawned, delivered, waiting, next,
                      reducer, mfa, spawn, monitor_pid, monitor_ref, timeout)
    end
  end

  defp stream_close(waiting, monitor_pid, monitor_ref, timeout) do
    for {_, {pid, _}} <- waiting do
      Process.unlink(pid)
    end
    send(monitor_pid, {:DOWN, monitor_ref})
    receive do
      {:DOWN, ^monitor_ref, _, _, {:shutdown, ^monitor_ref}} ->
        :ok
      {:DOWN, ^monitor_ref, _, _, reason} ->
        exit({reason, {__MODULE__, :stream, [timeout]}})
    end
    stream_cleanup_inbox(monitor_ref)
  end

  defp stream_cleanup_inbox(monitor_ref) do
    receive do
      {{^monitor_ref, _}, _} ->
        stream_cleanup_inbox(monitor_ref)
      {:DOWN, {^monitor_ref, _}, _} ->
        stream_cleanup_inbox(monitor_ref)
    after
      0 ->
        :ok
    end
  end

  defp stream_mfa({mod, fun, args}, arg), do: {mod, fun, [arg | args]}
  defp stream_mfa(fun, arg), do: {:erlang, :apply, [fun, [arg]]}

  defp stream_spawn(value, spawned, waiting, mfa, spawn, monitor_pid, monitor_ref) do
    owner = self()
    {type, pid} = spawn.(owner, stream_mfa(mfa, value))
    send(monitor_pid, {:UP, owner, monitor_ref, spawned, type, pid})
    Map.put(waiting, spawned, {pid, :running})
  end

  defp stream_monitor(parent_pid) do
    parent_ref = Process.monitor(parent_pid)
    receive do
      {^parent_pid, monitor_ref} ->
        stream_monitor(parent_pid, parent_ref, monitor_ref, %{})
      {:DOWN, ^parent_ref, _, _, reason} ->
        exit(reason)
    end
  end

  defp stream_monitor(parent_pid, parent_ref, monitor_ref, counters) do
    receive do
      {:UP, owner, ^monitor_ref, counter, type, pid} ->
        ref = Process.monitor(pid)
        send(pid, {owner, {monitor_ref, counter}})
        counters = Map.put(counters, ref, {counter, type, pid})
        stream_monitor(parent_pid, parent_ref, monitor_ref, counters)
      {:DOWN, ^monitor_ref} ->
        for {ref, {_counter, _, pid}} <- counters do
          Process.exit(pid, :kill)
          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          end
        end
        exit({:shutdown, monitor_ref})
      {:DOWN, ^parent_ref, _, _, reason} ->
        for {_ref, {_counter, :link, pid}} <- counters do
          Process.exit(pid, reason)
        end
        exit(reason)
      {:DOWN, ref, _, _, reason} ->
        {{counter, _, _}, counters} = Map.pop(counters, ref)
        send(parent_pid, {:DOWN, {monitor_ref, counter}, reason})
        stream_monitor(parent_pid, parent_ref, monitor_ref, counters)
    end
  end
end
