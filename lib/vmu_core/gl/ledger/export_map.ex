defmodule VmuCore.GL.ExportMap do
  @moduledoc """
  Translates internal GL account codes into the codes a bank's core banking
  system expects (Phase 4A.1).

  ## Why this exists before it is needed

  `CMS.CoreBankingAdapter` sends `gl_account_dr`/`gl_account_cr` to the bank's
  own general ledger. Today nothing consumes it — the adapter has never been
  configured for a live mode and no row has ever been extracted. That is
  precisely why this is the moment to build the indirection: once a bank
  starts receiving extracts, the codes in them are fixed, and adding a
  translation layer afterwards means renegotiating an integration rather than
  editing a module.

  It is also WAY4's own model. WAY4 does not assume its account numbers match
  the bank's — a WAY4 GL account is explicitly *a mirror of* a CBS account,
  registered against the bank's chart. This is that mirror.

  ## Default behaviour

  Identity. With no configuration, `translate/1` returns its input unchanged
  and the extract payload is byte-identical to what it was before this module
  existed. A bank that wants different codes supplies a map:

      config :vmu_core, VmuCore.GL.ExportMap,
        accounts: %{
          "2004" => "210401",   # our Debit Deposit Liability → their code
          "3002" => "100250"
        }

  Configured per deployment rather than per row, because the mapping is a
  property of the receiving institution.
  """

  alias VmuCore.GL.ChartOfAccounts

  @doc """
  Translates one internal code to its external equivalent.

  Unmapped codes pass through unchanged — a partial mapping is normal, since
  most banks accept the majority of codes as-is and rename only a few.
  """
  @spec translate(String.t() | nil) :: String.t() | nil
  def translate(nil), do: nil

  def translate(code) when is_binary(code) do
    Map.get(account_map(), code, code)
  end

  @doc """
  Translates the `gl_account_dr` / `gl_account_cr` keys of an extract entry,
  leaving every other field untouched.

  Accepts string or atom keys — extract payloads are built with atom keys but
  round-trip through JSON as strings.
  """
  @spec translate_entry(map()) :: map()
  def translate_entry(entry) when is_map(entry) do
    entry
    |> translate_key(:gl_account_dr)
    |> translate_key(:gl_account_cr)
    |> translate_key("gl_account_dr")
    |> translate_key("gl_account_cr")
  end

  @doc "The configured mapping. Empty by default."
  @spec account_map() :: %{String.t() => String.t()}
  def account_map do
    :vmu_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:accounts, %{})
  end

  @doc "True when no translation is configured — the extract is pass-through."
  @spec identity?() :: boolean()
  def identity?, do: account_map() == %{}

  @doc """
  Validates the configured mapping against the chart of accounts.

  Returns `{:error, unknown_codes}` when the mapping references internal codes
  that do not exist — a typo there would silently send a bank the wrong
  account for every entry, which is worth catching at boot rather than in a
  month-end reconciliation.
  """
  @spec validate() :: :ok | {:error, [String.t()]}
  def validate do
    unknown =
      account_map()
      |> Map.keys()
      |> Enum.reject(&ChartOfAccounts.get/1)

    if unknown == [], do: :ok, else: {:error, unknown}
  end

  defp translate_key(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, code} -> Map.put(entry, key, translate(code))
      :error      -> entry
    end
  end
end
