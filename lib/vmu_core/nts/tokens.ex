defmodule VmuCore.NTS.Tokens do
  @moduledoc """
  Context for `NTS.Token` — the API for the token lifecycle's persistence
  layer. `transition/3` is the only status write path (mirrors `CTA.Cards.
  transition/3`'s shape): validated against a small fixed transition table,
  stamps the matching lifecycle timestamp.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.NTS.Token

  @transitions %{
    "PENDING"   => ~w[PUSHED ACTIVE DELETED],
    "PUSHED"    => ~w[ACTIVE DELETED],
    "ACTIVE"    => ~w[SUSPENDED DELETED],
    "SUSPENDED" => ~w[ACTIVE DELETED],
    "DELETED"   => ~w[]
  }

  @doc "Create a new token record, status PENDING unless attrs override it."
  @spec create(map()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Token{}
    |> Token.changeset(Map.put_new(attrs, "status", "PENDING"))
    |> Repo.insert()
  end

  @spec get(binary()) :: Token.t() | nil
  def get(token_id), do: Repo.get(Token, token_id)

  @spec by_dpan(String.t()) :: Token.t() | nil
  def by_dpan(dpan), do: Repo.get_by(Token, dpan: dpan)

  @doc "All non-deleted tokens for a card, newest first."
  @spec list_for_card(binary()) :: [Token.t()]
  def list_for_card(card_id) do
    Repo.all(
      from t in Token,
        where: t.card_id == ^card_id and t.status != "DELETED",
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "All non-deleted tokens across several cards, newest first — for admin console listings covering every generation of a card on one account."
  @spec list_for_cards([binary()]) :: [Token.t()]
  def list_for_cards(card_ids) do
    Repo.all(
      from t in Token,
        where: t.card_id in ^card_ids and t.status != "DELETED",
        order_by: [desc: t.inserted_at]
    )
  end

  @doc """
  Move a token to `new_status`. Returns `{:error, :invalid_transition}` for
  a transition not in the fixed table above (e.g. re-deleting an already
  DELETED token) rather than silently no-op-ing.
  """
  @spec transition(binary() | Token.t(), String.t()) :: {:ok, Token.t()} | {:error, term()}
  def transition(%Token{} = token, new_status), do: transition(token.token_id, new_status)

  def transition(token_id, new_status) do
    case get(token_id) do
      nil ->
        {:error, :token_not_found}

      token ->
        if new_status in Map.get(@transitions, token.status, []) do
          token
          |> Token.changeset(stamp(%{"status" => new_status}, token.status, new_status))
          |> Repo.update()
        else
          {:error, :invalid_transition}
        end
    end
  end

  @doc """
  Re-point a card's live tokens to a new card row without any TSP call —
  used when `CardLifecycle.replace/3`/`renew/2` issue a new generation of
  the *same* PAN (DAMAGED replace, or any renewal): the DPAN↔PAN mapping
  MDES holds is still valid, only vmu_core's own `card_id` reference needs
  to follow the new plastic.
  """
  @spec migrate_card_id(binary(), binary()) :: :ok
  def migrate_card_id(old_card_id, new_card_id) do
    Repo.update_all(
      from(t in Token, where: t.card_id == ^old_card_id and t.status != "DELETED"),
      set: [card_id: new_card_id, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
  end

  # provisioned_at is stamped only on first real activation (PENDING/PUSHED
  # -> ACTIVE) — a later resume (SUSPENDED -> ACTIVE) must not overwrite it.
  defp stamp(attrs, old, "ACTIVE") when old in ["PENDING", "PUSHED"], do: Map.put(attrs, "provisioned_at", now())
  defp stamp(attrs, _old_status, "SUSPENDED"), do: Map.put(attrs, "suspended_at", now())
  defp stamp(attrs, _old_status, "DELETED"), do: Map.put(attrs, "deleted_at", now())
  defp stamp(attrs, _old_status, _new_status), do: attrs

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
