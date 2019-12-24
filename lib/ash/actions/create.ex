defmodule Ash.Actions.Create do
  alias Ash.Authorization.Authorizer
  alias Ash.Actions.ChangesetHelpers

  @spec run(Ash.api(), Ash.resource(), Ash.action(), Ash.params()) ::
          {:ok, Ash.record()} | {:error, Ecto.Changeset.t()} | {:error, Ash.error()}
  def run(api, resource, action, params) do
    if Keyword.get(params, :side_load, []) in [[], nil] do
      case prepare_create_params(api, resource, params) do
        %Ecto.Changeset{valid?: true} = changeset ->
          user = Keyword.get(params, :user)

          precheck_data = do_authorize(params, action, user, resource, changeset)

          if precheck_data == :forbidden do
            {:error, :forbidden}
          else
            do_create(resource, changeset)
          end

        %Ecto.Changeset{} = changeset ->
          {:error, changeset}
      end
    else
      {:error, "Cannot side load on create currently"}
    end
  end

  defp do_authorize(params, action, user, resource, changeset) do
    if Keyword.get(params, :authorize?, false) do
      auth_request =
        Ash.Authorization.Request.new(
          resource: resource,
          authorization_steps: action.authorization_steps,
          changeset: changeset
        )

      Authorizer.authorize(user, %{}, [auth_request])
    else
      :authorized
    end
  end

  defp do_create(resource, changeset) do
    if Ash.data_layer_can?(resource, :transact) do
      Ash.data_layer(resource).transaction(fn ->
        with %{valid?: true} = changeset <- ChangesetHelpers.run_before_changes(changeset),
             {:ok, result} <- Ash.DataLayer.create(resource, changeset) do
          ChangesetHelpers.run_after_changes(changeset, result)
        end
      end)
    else
      with %{valid?: true} = changeset <- ChangesetHelpers.run_before_changes(changeset),
           {:ok, result} <- Ash.DataLayer.create(resource, changeset) do
        ChangesetHelpers.run_after_changes(changeset, result)
      end
    end
  end

  defp prepare_create_params(api, resource, params) do
    attributes = Keyword.get(params, :attributes, %{})
    relationships = Keyword.get(params, :relationships, %{})
    authorize? = Keyword.get(params, :authorize?, false)
    user = Keyword.get(params, :user)

    case prepare_create_attributes(resource, attributes) do
      %{valid?: true} = changeset ->
        changeset = Map.put(changeset, :__ash_api__, api)

        ChangesetHelpers.prepare_relationship_changes(
          changeset,
          resource,
          relationships,
          authorize?,
          user
        )

      changeset ->
        changeset
    end
  end

  defp prepare_create_attributes(resource, attributes) do
    allowed_keys =
      resource
      |> Ash.attributes()
      |> Enum.map(& &1.name)

    attributes_with_defaults =
      resource
      |> Ash.attributes()
      |> Stream.filter(&(not is_nil(&1.default)))
      |> Enum.reduce(attributes, fn attr, attributes ->
        if Map.has_key?(attributes, attr.name) do
          attributes
        else
          Map.put(attributes, attr.name, default(attr))
        end
      end)

    resource
    |> struct()
    |> Ecto.Changeset.cast(attributes_with_defaults, allowed_keys)
    |> Map.put(:action, :create)
  end

  defp default(%{default: {:constant, value}}), do: value
  defp default(%{default: {mod, func}}), do: apply(mod, func, [])
  defp default(%{default: function}), do: function.()
end
