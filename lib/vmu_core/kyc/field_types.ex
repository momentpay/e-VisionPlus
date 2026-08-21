defmodule VmuCore.Kyc.FieldTypes do
  @moduledoc """
  Fixed, compile-time catalog of KYC form field types (`docs/kyc/KYC_Implementation_Tracker.md`
  §3.2) — matches the MMS reference's own `config/forms.php` and Avenza's
  `wallet_kyc` field-type catalog (both real, proven twice).

  Adding a genuinely new *kind* of input widget is a code change here; adding a
  new field *instance* of an existing type on a method is fully runtime-dynamic
  (just another entry in `kyc_methods.fields`).

  `"group"` is a repeatable sub-field container (e.g. "Shareholders," each
  instance holding its own set of sub-fields) — its `group_fields` key holds
  another array of field defs, not validated recursively here (the builder UI
  is responsible for keeping group depth to one level).
  """

  @types ~w[text number email tel textarea select radio checkbox date url
            password file divider heading group]

  @doc "The fixed list of supported field type keys."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "Human-readable label for a field type, for the builder UI's type dropdown."
  @spec label(String.t()) :: String.t()
  def label("text"), do: "Text Input"
  def label("number"), do: "Number"
  def label("email"), do: "Email"
  def label("tel"), do: "Phone"
  def label("textarea"), do: "Multi-line Text"
  def label("select"), do: "Dropdown"
  def label("radio"), do: "Radio Buttons"
  def label("checkbox"), do: "Checkbox"
  def label("date"), do: "Date"
  def label("url"), do: "URL"
  def label("password"), do: "Password"
  def label("file"), do: "File Upload"
  def label("divider"), do: "Divider (layout only)"
  def label("heading"), do: "Section Heading (layout only)"
  def label("group"), do: "Repeatable Group"
  def label(other), do: other

  @doc "Whether this type takes user input at all (divider/heading are layout-only)."
  @spec input_type?(String.t()) :: boolean()
  def input_type?(type), do: type not in ~w[divider heading]

  @doc "Whether this type offers a static `options` list (select/radio/checkbox)."
  @spec has_options?(String.t()) :: boolean()
  def has_options?(type), do: type in ~w[select radio checkbox]

  @doc "Whether uploaded field values for this type are files (drives document-viewer/OCR eligibility)."
  @spec file_type?(String.t()) :: boolean()
  def file_type?(type), do: type == "file"

  @doc "Whether this type is the repeatable sub-field container."
  @spec group_type?(String.t()) :: boolean()
  def group_type?(type), do: type == "group"

  @doc "Whether the given string is a recognized field type."
  @spec valid?(String.t()) :: boolean()
  def valid?(type), do: type in @types

  @doc """
  Per-type basic validation-rule builder for a submitted field value — mirrors
  the reference's `buildFieldValidationRules` (format checks only; `required`
  and any per-field `validation` map are applied by the caller, not here).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_value(String.t(), term()) :: :ok | {:error, String.t()}
  def validate_value(_type, nil), do: :ok
  def validate_value(_type, ""), do: :ok

  def validate_value("email", value) when is_binary(value) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value),
      do: :ok,
      else: {:error, "must be a valid email"}
  end

  def validate_value("number", value) when is_binary(value) do
    case Float.parse(value) do
      {_num, ""} -> :ok
      _ -> {:error, "must be a number"}
    end
  end

  def validate_value("url", value) when is_binary(value) do
    if Regex.match?(~r/^https?:\/\/\S+$/, value),
      do: :ok,
      else: {:error, "must be a valid URL"}
  end

  def validate_value("date", value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      _ -> {:error, "must be a valid date (YYYY-MM-DD)"}
    end
  end

  def validate_value(_type, _value), do: :ok
end
