defmodule VmuCore.Shared.Registry do
  @moduledoc """
  Horde-backed distributed registry for per-account GenServer processes.
  Processes registered here are accessible from any node in the cluster.
  """

  @registry_name __MODULE__
  @supervisor_name VmuCore.Shared.AccountSupervisor

  @doc "Look up a registered process by key. Returns [{pid, value}] or []."
  def lookup(key), do: Horde.Registry.lookup(@registry_name, key)

  @doc "Register the calling process under key."
  def register(key), do: Horde.Registry.register(@registry_name, key, nil)

  @doc "Start a child under the distributed supervisor."
  def start_child(child_spec), do: Horde.DynamicSupervisor.start_child(@supervisor_name, child_spec)
end
