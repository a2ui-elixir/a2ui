defmodule Site.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([SiteWeb.Endpoint], strategy: :one_for_one, name: Site.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SiteWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
