defmodule Ash.Actions.Read do
  alias Ash.Engine
  alias Ash.Engine.Request
  alias Ash.Actions.SideLoad
  require Logger

  def run(query, opts \\ []) do
    with %{errors: []} <- query,
         {:action, action} when not is_nil(action) <- {:action, action(query, opts)},
         requests <- requests(query, action, opts),
         {:ok, side_load_requests} <- Ash.Actions.SideLoad.requests(query),
         %{data: %{data: %{data: data}} = all_data, errors: [], authorized?: true} <-
           run_requests(requests ++ side_load_requests, query.api, opts),
         data_with_side_loads <- SideLoad.attach_side_loads(data, all_data) do
      {:ok, data_with_side_loads}
    else
      {:action, nil} ->
        {:error, "No such action defined, or no default action defined"}

      %{errors: errors} ->
        {:error, Ash.to_ash_error(errors)}

      {:error, error} ->
        {:error, Ash.to_ash_error(error)}
    end
  end

  defp action(query, opts) do
    case opts[:action] do
      %Ash.Resource.Actions.Read{name: name} ->
        Ash.action(query.resource, name, :read)

      nil ->
        Ash.primary_action(query.resource, :read)

      action ->
        Ash.action(query.resource, action, :read)
    end
  end

  def run_requests(requests, api, opts) do
    if opts[:authorization] do
      Engine.run(
        requests,
        api,
        user: opts[:authorization][:user],
        bypass_strict_access?: opts[:authorization][:bypass_strict_access?],
        verbose?: opts[:verbose?]
      )
    else
      Engine.run(requests, api, fetch_only?: true, verbose?: opts[:verbose?])
    end
  end

  defp requests(query, action, opts) do
    request =
      Request.new(
        resource: query.resource,
        rules: action.rules,
        query: query,
        action_type: action.type,
        strict_access?: !Ash.Filter.primary_key_filter?(query.filter),
        data: data_field(opts, query.filter, query.resource, query.data_layer_query),
        resolve_when_fetch_only?: true,
        path: [:data],
        name: "#{action.type} - `#{action.name}`"
      )

    [request | Map.get(query.filter || %{}, :requests, [])]
  end

  defp data_field(params, filter, resource, query) do
    if params[:initial_data] do
      List.wrap(params[:initial_data])
    else
      Request.resolve(
        [[:data, :query]],
        Ash.Filter.optional_paths(filter),
        fn %{data: %{query: ash_query}} = data ->
          fetch_filter = Ash.Filter.request_filter_for_fetch(ash_query.filter, data)

          with {:ok, query} <- Ash.DataLayer.filter(query, fetch_filter, resource),
               {:ok, query} <- Ash.DataLayer.limit(query, ash_query.limit, resource),
               {:ok, query} <- Ash.DataLayer.offset(query, ash_query.offset, resource) do
            Ash.DataLayer.run_query(query, resource)
          end
        end
      )
    end
  end
end
