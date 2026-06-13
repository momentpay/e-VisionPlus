defmodule VmuCore.CTA.StockInventory do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias VmuCore.Repo

  @primary_key {:stock_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[ORDERED DELIVERED ACTIVE DEPLETED RECALLED]

  schema "cta_card_stock" do
    field :sys_id,            :string
    field :bank_id,           :string
    field :logo_id,           :string
    field :bin_prefix,        :string
    field :batch_number,      :string
    field :quantity_ordered,  :integer
    field :quantity_on_hand,  :integer, default: 0
    field :quantity_issued,   :integer, default: 0
    field :quantity_damaged,  :integer, default: 0
    field :bureau_name,       :string
    field :order_date,        :date
    field :delivery_date,     :date
    field :expiry_year_month, :string
    field :status,            :string, default: "ORDERED"

    timestamps()
  end

  def changeset(stock, attrs) do
    stock
    |> cast(attrs, [:sys_id, :bank_id, :logo_id, :bin_prefix, :batch_number,
                    :quantity_ordered, :quantity_on_hand, :quantity_issued,
                    :quantity_damaged, :bureau_name, :order_date, :delivery_date,
                    :expiry_year_month, :status])
    |> validate_required([:sys_id, :bank_id, :logo_id, :bin_prefix, :batch_number,
                          :quantity_ordered, :order_date])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:batch_number)
  end

  @doc "Reserve one card from available stock. Returns {:ok, stock} or {:error, :no_stock}."
  def reserve_one(sys_id, logo_id) do
    Repo.transaction(fn ->
      stock = Repo.one(
        from s in __MODULE__,
          where: s.sys_id == ^sys_id
            and s.logo_id == ^logo_id
            and s.status == "ACTIVE"
            and s.quantity_on_hand > 0,
          order_by: [asc: s.order_date],
          limit: 1,
          lock: "FOR UPDATE"
      )

      case stock do
        nil ->
          Repo.rollback(:no_stock)

        s ->
          Repo.update_all(
            from(st in __MODULE__, where: st.stock_id == ^s.stock_id),
            inc: [quantity_issued: 1, quantity_on_hand: -1]
          )

          s
      end
    end)
  end

  @doc "Record a damaged/returned card back to stock."
  def record_damage(stock_id) do
    Repo.update_all(
      from(s in __MODULE__, where: s.stock_id == ^stock_id),
      inc: [quantity_damaged: 1, quantity_on_hand: -1]
    )
  end
end
