import { AgCharts } from "ag-charts-enterprise"

// ---------------------------------------------------------------------------
// The server -> chart contract
//
//   data-chart-type   "bar" | "line" | "donut"
//   data-chart-title  string, optional
//   data-chart-data   [{ <category-field>: ..., <value-field>: number, ... }]
//   data-category     field name for the x-axis / donut slice label
//   data-series       JSON array of { field, name } — one series per line/bar;
//                      donut uses only the first entry
//
// One shared palette so a status colour means the same thing in a chart as it
// does in a badge elsewhere on the same screen (see BADGE_CLASS in
// ag_grid_hook.js) — kept here as a plain, ordered fallback for categories
// that aren't badge statuses.
// ---------------------------------------------------------------------------

const PALETTE = ["#2563eb", "#16a34a", "#d97706", "#dc2626", "#7c3aed", "#0891b2", "#db2777"]

function readJSON(el, attr, fallback) {
  const raw = el.getAttribute(attr)
  if (!raw) return fallback
  try {
    return JSON.parse(raw)
  } catch (e) {
    console.error(`[AgChart] could not parse ${attr} on #${el.id}:`, e)
    return fallback
  }
}

function buildOptions(el) {
  const type = el.dataset.chartType || "bar"
  const data = readJSON(el, "data-chart-data", [])
  const category = el.dataset.category || "label"
  const series = readJSON(el, "data-series", [{ field: "value", name: "Value" }])
  const title = el.dataset.chartTitle

  const common = {
    container: el,
    data,
    theme: {
      palette: { fills: PALETTE, strokes: PALETTE },
      overrides: {
        common: {
          title: { fontFamily: "inherit" },
          axes: { category: { label: { fontFamily: "inherit" } }, number: { label: { fontFamily: "inherit" } } }
        }
      }
    }
  }

  if (title) common.title = { text: title }

  if (type === "donut") {
    return {
      ...common,
      series: [
        {
          type: "donut",
          angleKey: series[0].field,
          calloutLabelKey: category,
          innerRadiusRatio: 0.65
        }
      ]
    }
  }

  return {
    ...common,
    series: series.map((s) => ({
      type,
      xKey: category,
      yKey: s.field,
      yName: s.name
    }))
  }
}

const AgChart = {
  mounted() {
    this.chart = AgCharts.create(buildOptions(this.el))
    this._lastData = this.el.getAttribute("data-chart-data")
  },

  updated() {
    const dataJSON = this.el.getAttribute("data-chart-data")
    if (dataJSON === this._lastData && this.chart) return
    this._lastData = dataJSON

    // Rebuilt rather than patched — the shape of a dashboard chart (series,
    // category set) can change between renders, and AgCharts.update expects
    // the same series shape it was created with.
    if (this.chart) this.chart.destroy()
    this.chart = AgCharts.create(buildOptions(this.el))
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
      this.chart = null
    }
  }
}

export default AgChart
