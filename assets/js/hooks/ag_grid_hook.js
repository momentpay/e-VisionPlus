import { createGrid, ModuleRegistry, AllCommunityModule } from "ag-grid-community"
import { AllEnterpriseModule, LicenseManager } from "ag-grid-enterprise"

ModuleRegistry.registerModules([AllCommunityModule, AllEnterpriseModule])

const licenseMeta = document.querySelector('meta[name="ag-grid-license"]')
if (licenseMeta && licenseMeta.content) {
  LicenseManager.setLicenseKey(licenseMeta.content)
}

// ---------------------------------------------------------------------------
// The server → grid contract
//
// AdminLive's LiveComponents pass two data attributes, both plain JSON with
// no functions in them (so they survive Jason.encode!/1 and DOM attribute
// serialization unchanged):
//
//   data-columns  [{ field, header, type?, width?, flex?, sortable?,
//                     filter?, actions? }]
//   data-rows     [{ <field>: <value>, ... }]
//
// `type` picks a cell treatment — see cellDefForColumn below. `actions` (only
// on an "actions" column) is [{ label, event, param }]: clicking pushes
// `event` to the LiveComponent with `{"id" => row[param]}`.
//
// See docs/shared/Admin_Menu_Standard.md §5 for the full contract and the
// HEEx side (VmuCoreWeb.Components.AgGrid.ag_grid/1).
// ---------------------------------------------------------------------------

const numberFormatter = new Intl.NumberFormat(undefined, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
})

function formatMoney(params) {
  if (params.value === null || params.value === undefined || params.value === "") return "—"
  const n = Number(params.value)
  return Number.isNaN(n) ? String(params.value) : numberFormatter.format(n)
}

function formatNumber(params) {
  if (params.value === null || params.value === undefined || params.value === "") return "—"
  const n = Number(params.value)
  return Number.isNaN(n) ? String(params.value) : n.toLocaleString()
}

function formatDate(params) {
  if (!params.value) return "—"
  // Server sends ISO-ish strings (Date/DateTime/NaiveDateTime to_string) —
  // reformat what parses cleanly, and show anything else verbatim rather
  // than guessing at its shape.
  const d = new Date(params.value)
  if (Number.isNaN(d.getTime())) return String(params.value)
  return d.toLocaleString(undefined, {
    year: "numeric", month: "short", day: "numeric",
    hour: "2-digit", minute: "2-digit"
  })
}

const BADGE_CLASS = {
  ACTIVE: "badge-green", ENABLED: "badge-green", TRUE: "badge-green", OK: "badge-green",
  VERIFIED: "badge-green", APPROVED: "badge-green", DONE: "badge-green",
  INACTIVE: "badge-red", DISABLED: "badge-red", FALSE: "badge-red",
  REJECTED: "badge-red", FAILED: "badge-red", DECLINED: "badge-red",
  PENDING: "badge-yellow", DRAFT: "badge-yellow", SUBMITTED: "badge-yellow", WARNING: "badge-yellow"
}

function badgeCellRenderer(params) {
  if (params.value === null || params.value === undefined || params.value === "") return "—"
  const value = String(params.value)
  // `classField` lets a screen with its own status vocabulary (not the
  // generic ACTIVE/PENDING/etc set) supply the badge class per row —
  // e.g. Audit Trail's action severity (info/warning/error), which
  // doesn't fit the fixed BADGE_CLASS map below.
  const classField = params.colDef.classField
  const cls = (classField && params.data[classField]) || BADGE_CLASS[value.toUpperCase()] || "badge-gray"
  const span = document.createElement("span")
  span.className = `badge ${cls}`
  span.textContent = value
  return span
}

function monoCellRenderer(params) {
  if (params.value === null || params.value === undefined || params.value === "") return "—"
  const span = document.createElement("span")
  span.className = "mono"
  span.textContent = params.value
  return span
}

// A real page navigation (<a href>), not a LiveView event — for cross-module
// deep links like "View in Debit Cards" (Koṣa Arrangement-style cross-product
// links), where clicking leaves this LiveView entirely rather than pushing
// an event to it. `hrefField` names the row field holding the URL; the
// cell's own field value is the link text.
function linkCellRenderer(params) {
  if (params.value === null || params.value === undefined || params.value === "") return "—"
  const hrefField = params.colDef.hrefField
  const href = hrefField && params.data[hrefField]
  if (!href) return String(params.value)

  const a = document.createElement("a")
  a.className = "btn btn-ghost btn-xs"
  a.href = href
  a.textContent = params.value
  return a
}

// Fills `{field_name}` placeholders in a confirm message from the row data —
// e.g. "Delete block {block_id}?" -> "Delete block K042?". Plain string
// substitution, not a template language: keeps `actions` JSON-safe (no
// functions) while still letting a destructive action's prompt name the
// specific row, the way every hand-written `data-confirm` already did.
function fillTemplate(template, data) {
  return template.replace(/\{(\w+)\}/g, (match, field) =>
    Object.prototype.hasOwnProperty.call(data, field) ? data[field] : match
  )
}

function actionsCellRenderer(hook) {
  return function (params) {
    const wrap = document.createElement("div")
    wrap.className = "actions"
    for (const action of params.colDef.actions || []) {
      // `whenField`/`whenValue` hide an action that doesn't apply to this
      // row — e.g. "Revoke" only where status is ACTIVE — the same
      // conditional-action pattern every hand-written table already used.
      if (action.whenField && params.data[action.whenField] !== action.whenValue) continue

      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = `btn btn-ghost btn-xs${action.danger ? " btn-danger-text" : ""}`
      btn.textContent = action.label
      btn.addEventListener("click", () => {
        // `confirm` mirrors the data-confirm safety prompt every irreversible
        // action elsewhere in this app carries — an action here that skips
        // it when the original had one is a regression, not a simplification.
        if (action.confirm && !window.confirm(fillTemplate(action.confirm, params.data))) return

        // `params` carries extra *static* values into the payload alongside
        // the row's own id — for a handler keyed on more than the record,
        // e.g. card_action_open's %{"a" => "card_block", "id" => card_id},
        // where one event serves several buttons and `a` says which. Row
        // data still wins nothing here: these are per-action constants
        // declared server-side, never client-derived.
        hook.pushEventTo(hook.el, action.event, {
          ...(action.params || {}),
          id: params.data[action.param]
        })
      })
      wrap.appendChild(btn)
    }
    return wrap
  }
}

function cellDefForColumn(col, hook) {
  const def = {
    field: col.field,
    headerName: col.header ?? col.field,
    sortable: col.sortable ?? true,
    filter: col.filter ?? true,
    resizable: true
  }

  if (col.width) def.width = col.width
  if (col.flex) def.flex = col.flex
  if (!col.width && !col.flex) def.flex = 1

  switch (col.type) {
    case "money":
      def.valueFormatter = formatMoney
      def.cellClass = "ag-right-aligned-cell num"
      def.type = "rightAligned"
      break
    case "number":
      def.valueFormatter = formatNumber
      def.cellClass = "ag-right-aligned-cell num"
      def.type = "rightAligned"
      break
    case "date":
      def.valueFormatter = formatDate
      break
    case "badge":
      def.cellRenderer = badgeCellRenderer
      def.classField = col.classField
      def.filter = false
      break
    case "mono":
      def.cellRenderer = monoCellRenderer
      break
    case "link":
      def.cellRenderer = linkCellRenderer
      def.hrefField = col.hrefField
      def.sortable = col.sortable ?? false
      def.filter = false
      break
    case "actions":
      def.cellRenderer = actionsCellRenderer(hook)
      def.actions = col.actions || []
      def.sortable = false
      def.filter = false
      def.resizable = false
      break
    default:
      break
  }

  return def
}

function readJSON(el, attr, fallback) {
  const raw = el.getAttribute(attr)
  if (!raw) return fallback
  try {
    return JSON.parse(raw)
  } catch (e) {
    console.error(`[AgGrid] could not parse ${attr} on #${el.id}:`, e)
    return fallback
  }
}

const AgGrid = {
  mounted() {
    const columns = readJSON(this.el, "data-columns", [])
    const rows = readJSON(this.el, "data-rows", [])

    const paginate = this.el.dataset.paginate !== "false"

    // `data-row-class-field` names a row field holding a CSS class for the
    // whole row — how a table flags an exceptional row (a GL shadow-diff
    // mismatch, the wallet currency currently in view). Without it those
    // highlights would quietly vanish in the move off hand-written <tr>.
    const rowClassField = this.el.dataset.rowClassField

    this.gridApi = createGrid(this.el, {
      theme: "legacy",
      columnDefs: columns.map((c) => cellDefForColumn(c, this)),
      rowData: rows,
      getRowClass: rowClassField ? (p) => p.data && p.data[rowClassField] : undefined,
      animateRows: true,
      pagination: paginate,
      paginationPageSize: 50,
      paginationPageSizeSelector: paginate ? [25, 50, 100, 200] : false,
      domLayout: "autoHeight",
      suppressCellFocus: true,
      overlayNoRowsTemplate: this.el.dataset.emptyMessage || "No rows to show."
    })

    this._lastColumnsJSON = this.el.getAttribute("data-columns")
  },

  updated() {
    if (!this.gridApi) return

    const columnsJSON = this.el.getAttribute("data-columns")
    if (columnsJSON !== this._lastColumnsJSON) {
      const columns = readJSON(this.el, "data-columns", [])
      this.gridApi.setGridOption("columnDefs", columns.map((c) => cellDefForColumn(c, this)))
      this._lastColumnsJSON = columnsJSON
    }

    const rows = readJSON(this.el, "data-rows", [])
    this.gridApi.setGridOption("rowData", rows)
  },

  destroyed() {
    if (this.gridApi) {
      this.gridApi.destroy()
      this.gridApi = null
    }
  }
}

export default AgGrid
