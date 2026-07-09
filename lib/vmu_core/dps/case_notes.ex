defmodule VmuCore.DPS.CaseNotes do
  @moduledoc """
  Case notes + investigator assignment for dispute cases (FR-DPS-015).

  Notes are an append-only log (`VmuCore.DPS.DisputeNote`); assignment is the
  dispute's current `assigned_to` field. Both are audited via the existing
  `VmuCore.ASM.AuditLog` sink — no new audit table.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.DPS.{Dispute, DisputeNote}
  alias VmuCore.ASM.AuditLog

  @doc "Add a note to a dispute case. Returns `{:ok, note}` or `{:error, changeset}`."
  @spec add_note(Ecto.UUID.t(), String.t(), VmuCore.ASM.Operator.t() | nil) ::
          {:ok, DisputeNote.t()} | {:error, Ecto.Changeset.t()}
  def add_note(dispute_id, text, operator) do
    attrs = %{
      dispute_id: dispute_id,
      author: operator_name(operator),
      note: text,
      created_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    case %DisputeNote{} |> DisputeNote.changeset(attrs) |> Repo.insert() do
      {:ok, note} ->
        AuditLog.record(operator, "dispute_note_add", dispute_id, %{note_id: note.note_id})
        {:ok, note}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "All notes for a dispute, newest first."
  @spec list_notes(Ecto.UUID.t()) :: [DisputeNote.t()]
  def list_notes(dispute_id) do
    Repo.all(
      from n in DisputeNote,
        where: n.dispute_id == ^dispute_id,
        order_by: [desc: n.created_at]
    )
  end

  @doc """
  Assign (or unassign, with `nil`) an investigator to a dispute case.

  Uses a narrow `Repo.update_all` (not `Dispute.changeset/2`) deliberately —
  `changeset/2` also recomputes `chargeback_deadline`/`provisional_credit_deadline`
  from current config on every call (needed at filing time), which would silently
  drift a dispute's stored deadlines if config changed since filing, for a change
  that has nothing to do with deadlines. Same pattern `Dispute.transition/2` already
  uses for status updates.

  Returns `{:ok, dispute}` or `{:error, :dispute_not_found}`.
  """
  @spec assign(Ecto.UUID.t(), String.t() | nil, VmuCore.ASM.Operator.t() | nil) ::
          {:ok, Dispute.t()} | {:error, :dispute_not_found}
  def assign(dispute_id, assignee, operator) do
    case Repo.get(Dispute, dispute_id) do
      nil ->
        {:error, :dispute_not_found}

      dispute ->
        Repo.update_all(
          from(d in Dispute, where: d.dispute_id == ^dispute_id),
          set: [assigned_to: assignee, updated_at: NaiveDateTime.utc_now()]
        )

        AuditLog.record(operator, "dispute_assign", dispute_id, %{assigned_to: assignee})
        {:ok, %{dispute | assigned_to: assignee}}
    end
  end

  defp operator_name(nil), do: "system"
  defp operator_name(%{username: username}), do: username
end
