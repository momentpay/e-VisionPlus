defmodule VmuCore.Repo.Migrations.RedesignCmsCardPinsForRealHsm do
  use Ecto.Migration

  def change do
    # Way4 parity plan Phase 0 item 7 — the previous pin_hash/pin_salt
    # design decoded the ISO PIN block to plaintext digits in application
    # code and compared a PBKDF2 hash, which no real HSM/PCI-compliant
    # flow ever does (the PIN block must stay encrypted end-to-end; only
    # the HSM ever sees it). reference_pin_lmk replaces both columns: the
    # LMK-encrypted reference PIN block payShield's BE command ("Verify
    # an Interchange PIN Using the Comparison Method") compares against
    # internally. It is opaque outside the HSM — useless without the LMK
    # — so it is safe to store, unlike a hash of the actual PIN.
    alter table(:cms_card_pins) do
      add :reference_pin_lmk, :string
      remove :pin_hash, :string
      remove :pin_salt, :string
    end
  end
end
