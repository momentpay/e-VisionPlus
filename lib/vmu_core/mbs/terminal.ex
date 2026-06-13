defmodule VmuCore.MBS.Terminal do
  @moduledoc """
  MBS terminal — a physical or virtual acceptance device belonging to a merchant.

  terminal_code maps to ISO 8583 DE 41 (Card Acceptor Terminal Identification)
  and must be unique across the network. 8 characters, alphanumeric.

  terminal_type:
    POS     — chip-and-PIN point-of-sale device
    MPOS    — mobile POS (e.g., SumUp, Square reader)
    ATM     — Automated Teller Machine
    KIOSK   — unattended payment kiosk
    VIRTUAL — payment gateway, no physical device (e-commerce)

  Terminals with status=ACTIVE receive authorizations. SUSPENDED terminals
  get RC "58" (transaction not permitted to terminal) from the FAS authorization path.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:terminal_id, :binary_id, autogenerate: true}

  schema "mbs_terminals" do
    field :merchant_id,   :binary_id
    field :terminal_code, :string     # DE 41 — 8 chars
    field :terminal_type, :string     # POS | MPOS | ATM | KIOSK | VIRTUAL
    field :serial_number, :string
    field :installed_at,  :date
    field :status,        :string, default: "ACTIVE"

    belongs_to :merchant, VmuCore.MBS.Merchant,
      define_field: false,
      foreign_key: :merchant_id,
      references: :merchant_id

    timestamps()
  end

  @valid_types    ~w(POS MPOS ATM KIOSK VIRTUAL)
  @valid_statuses ~w(ACTIVE SUSPENDED DECOMMISSIONED)

  def changeset(terminal, attrs) do
    terminal
    |> cast(attrs, [:merchant_id, :terminal_code, :terminal_type,
                    :serial_number, :installed_at, :status])
    |> validate_required([:merchant_id, :terminal_code, :terminal_type])
    |> validate_inclusion(:terminal_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:terminal_code, is: 8)
    |> validate_format(:terminal_code, ~r/^[A-Z0-9]{8}$/, message: "must be 8 alphanumeric uppercase chars")
    |> unique_constraint(:terminal_code)
  end

  @doc "Check if a terminal is active (used in authorization path)."
  def active?(%__MODULE__{status: "ACTIVE"}), do: true
  def active?(_), do: false
end
