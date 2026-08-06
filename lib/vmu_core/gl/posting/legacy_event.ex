defmodule VmuCore.Posting.LegacyEvent do
  @moduledoc """
  Translates a legacy `InternalGlPoster` posting into a `Posting.RuleEngine`
  event (GL Phase C3).

  ## Why this exists as its own module

  Thirty-five modules call `CMS.InternalGlPoster`, and none of them knows its
  own institution: `post_interest(account_id, amount, posting_date, key)` knows
  an account and nothing more. The engine requires `sys_id`/`bank_id` — the
  period gate and GL consolidation both key on them.

  So *something* has to sit between the legacy call shape and the engine and
  recover the missing context. Rewriting all thirty-five call sites to pass an
  institution would push `InstitutionResolver` into thirty-five places and
  change every one of their signatures; this translation is the alternative,
  and it is why `InternalGlPoster` survives C3 as a façade rather than being
  deleted outright.

  This logic ran inside `Posting.Shadow` throughout Phase B, where its job was
  to *mirror* a legacy posting. In C3 the same translation became the only
  write path, so it moved here and both callers share it — a mirror and a
  system of record must not be able to disagree about what an event means.

  ## The two vocabularies genuinely differ

  `cms_ledger_entries.transaction_code` is a constrained enum with no
  `WITHDRAWAL` member, and both adjustment directions collapse onto one code.
  The engine separates them. Those two exceptions are where a silent
  mistranslation would hide, so they are handled explicitly rather than by a
  pass-through.
  """

  alias VmuCore.GL.InstitutionResolver

  @type legacy_attrs :: map()

  @doc """
  Builds a `RuleEngine` event from legacy posting attrs.

  Returns `{:error, reason}` when the account cannot be resolved to a product
  or an institution — the caller decides whether that is fatal.
  """
  @spec from_attrs(legacy_attrs(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_attrs(attrs, opts \\ []) do
    account_ref = to_string(attrs[:account_id])

    with {:ok, product} <- infer_product(account_ref),
         {:ok, event_type} <- infer_event_type(attrs, product),
         {:ok, {sys_id, bank_id}} <- InstitutionResolver.resolve(account_ref, product) do
      {:ok,
       %{
         event_type: event_type,
         product: product,
         account_ref: account_ref,
         amount: attrs[:dr_amount] || attrs[:cr_amount],
         idempotency_key: attrs[:idempotency_key],
         sys_id: sys_id,
         bank_id: bank_id,
         currency: attrs[:currency] || "AED",
         posting_date: attrs[:posting_date],
         gl_date: attrs[:posting_date],
         transaction_date: attrs[:value_date],
         bindings: attrs[:bindings] || %{},
         # Pass the caller's narrative straight through when it has one.
         #
         # Without this the engine falls back to the rule's
         # `narrative_template`, and legacy callers supply no bindings — so a
         # wallet load recorded the literal string "Wallet account load:
         # {channel}", placeholder and all, in place of the narrative the
         # caller actually wrote. Caught by `WalletW1Test` on the first full
         # run after the C3 inversion.
         narrative: attrs[:narrative],
         source_module: Keyword.get(opts, :source_module, "InternalGlPoster")
       }}
    end
  end

  @doc "Which product an account reference belongs to."
  @spec infer_product(String.t()) :: {:ok, String.t()} | {:error, term()}
  def infer_product(""), do: {:error, :no_account}

  def infer_product(account_ref) do
    # Ask the resolver which table the account lives in, rather than probing
    # each product in turn. The probing version was subtly wrong: it returned
    # whichever product was tried first once the account was cached, so a
    # credit account could look like a debit account. See the resolver moduledoc.
    InstitutionResolver.resolve_product(account_ref)
  end

  @doc """
  Maps a legacy `transaction_code` onto a posting-rule event type.
  """
  @spec infer_event_type(legacy_attrs(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def infer_event_type(attrs, product) do
    code = attrs[:transaction_code]
    dr = attrs[:gl_account_dr]

    # An explicit `:event_type` wins. This is the escape hatch from the legacy
    # enum, which is too coarse in places: COL's recovery posting is labelled
    # `PAYMENT` because `cms_ledger_entries.transaction_code` has no RECOVERY
    # member, but a recovery credits recovery income (4004) where a payment
    # credits the receivable. Under C3 the rule decides the accounts, so a
    # caller whose intent the legacy code cannot express has to say so — the
    # alternative is letting callers pass raw account pairs, which is exactly
    # the free-for-all that put two conflicting charts into one table.
    cond do
      is_binary(attrs[:event_type]) ->
        {:ok, attrs[:event_type]}

      true ->
        do_infer(code, product, dr)
    end
  end

  defp do_infer(code, product, dr) do
    case {code, product} do
      {"PURCHASE", "WALLET"} -> {:ok, "WITHDRAWAL"}
      {"ADJUSTMENT", _} -> {:ok, adjustment_direction(dr, product)}
      {nil, _} -> {:error, :no_transaction_code}
      {c, _} -> {:ok, c}
    end
  end

  # Direction is recoverable from which side the stored-value liability sits
  # on: debiting the liability reduces the customer's balance.
  defp adjustment_direction(dr_account, product) do
    liability =
      case product do
        "DEBIT" -> "2004"
        "PREPAID" -> "2005"
        "WALLET" -> "2006"
        _ -> nil
      end

    if dr_account == liability, do: "ADJUSTMENT_DEBIT", else: "ADJUSTMENT_CREDIT"
  end
end
