import { A } from '@solidjs/router'
import {
  type CellContext,
  createColumnHelper,
  createSortedRowModel,
  createTable,
  rowSortingFeature,
  sortFn_alphanumeric,
  sortFn_basic,
  tableFeatures,
} from '@tanstack/solid-table'
import { For, type JSX } from 'solid-js'

import { formatLong, formatPct, formatShort } from '../lib/units'
import { units } from '../state/store'
import { mapPath, municipalitySlug } from '../state/url'
import type { Score } from './measures'

const features = tableFeatures({
  rowSortingFeature,
  sortedRowModel: createSortedRowModel(),
  sortFns: { alphanumeric: sortFn_alphanumeric, basic: sortFn_basic },
})
const helper = createColumnHelper<typeof features, Score>()

const TYPE_LABEL = { city: 'City', village: 'Village', town: 'Town' }

function long(c: CellContext<typeof features, Score, number>): string {
  return formatLong(c.getValue(), units())
}

const columns = helper.columns([
  helper.accessor((s) => s.muni.name, {
    id: 'name',
    header: 'Municipality',
    sortFn: 'alphanumeric',
    // Jump to the map, focused on this municipality.
    cell: (c) =>
      c.row.original.muni.shore_bbox ? (
        <A
          class="link"
          href={mapPath({
            municipality: municipalitySlug(c.getValue()),
            bbox: undefined,
            seg: undefined,
          })}
        >
          {c.getValue()}
        </A>
      ) : (
        c.getValue()
      ),
  }),
  helper.accessor((s) => s.muni.muni_type, {
    id: 'type',
    header: 'Type',
    sortFn: 'alphanumeric',
    cell: (c) => TYPE_LABEL[c.getValue()],
  }),
  helper.accessor((s) => s.pct ?? -1, {
    id: 'pct',
    header: 'Share',
    sortFn: 'basic',
    cell: (c) => {
      const p = c.row.original.pct
      return p === null ? '—' : formatPct(p)
    },
  }),
  helper.accessor('numeratorM', { header: 'Counted', sortFn: 'basic', cell: long }),
  helper.accessor('denominatorM', { header: 'Out of', sortFn: 'basic', cell: long }),
  helper.accessor('perThousandM', {
    header: 'Per 1,000 residents',
    sortFn: 'basic',
    cell: (c) => formatShort(c.getValue(), units()),
  }),
  helper.accessor((s) => s.muni.population, {
    id: 'population',
    header: 'Population',
    sortFn: 'basic',
    cell: (c) => c.getValue().toLocaleString(),
  }),
])

export default function ScoreTable(props: { scores: Score[] }): JSX.Element {
  const table = createTable({
    features,
    columns,
    get data() {
      return props.scores
    },
    initialState: { sorting: [{ id: 'pct', desc: true }] },
  })

  return (
    <div class="table-wrap">
      <table class="scores">
        <thead>
          <For each={table.getHeaderGroups()}>
            {(group) => (
              <tr>
                <For each={group.headers}>
                  {(header) => {
                    function sorted(): false | 'asc' | 'desc' {
                      return header.column.getIsSorted()
                    }
                    return (
                      <th
                        classList={{
                          num: header.column.id !== 'name' && header.column.id !== 'type',
                        }}
                        aria-sort={
                          sorted() === 'asc'
                            ? 'ascending'
                            : sorted() === 'desc'
                              ? 'descending'
                              : 'none'
                        }
                      >
                        <button onClick={header.column.getToggleSortingHandler()}>
                          <table.FlexRender header={header} />
                          <span class="sort" aria-hidden="true">
                            {sorted() === 'asc' ? '▲' : sorted() === 'desc' ? '▼' : ''}
                          </span>
                        </button>
                      </th>
                    )
                  }}
                </For>
              </tr>
            )}
          </For>
        </thead>
        <tbody>
          <For each={table.getRowModel().rows}>
            {(row) => (
              <tr>
                <For each={row.getAllCells()}>
                  {(cell) => (
                    <td
                      classList={{
                        num: cell.column.id !== 'name' && cell.column.id !== 'type',
                      }}
                    >
                      <table.FlexRender cell={cell} />
                    </td>
                  )}
                </For>
              </tr>
            )}
          </For>
        </tbody>
      </table>
    </div>
  )
}
