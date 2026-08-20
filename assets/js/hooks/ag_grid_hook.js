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
        hook.pushEventTo(hook.el, action.event, { id: params.data[action.param] })
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

    this.gridApi = createGrid(this.el, {
      theme: "legacy",
      columnDefs: columns.map((c) => cellDefForColumn(c, this)),
      rowData: rows,
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
