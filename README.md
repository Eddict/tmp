# tmp
repo to share (raw) tmp files via url

## Database diagrams

Grouped diagrams of [`pgsql_db.sql`](pgsql_db.sql): 105 tables, 610 columns
(including inherited columns), 110 foreign-key constraints, and 2 inheritance relationships.

[Download the complete PDF](database-diagrams/pgsql-database-diagrams.pdf).
The [HTML viewer](database-diagrams/index.html) can be downloaded and opened locally.
Each group includes a PNG, a zoomable SVG, and editable Graphviz (`.dot`) source.

| Group | Diagram | SVG | Source |
|---|---|---|---|
| Media and files | [PNG](database-diagrams/01-media.png) | [SVG](database-diagrams/01-media.svg) | [DOT](database-diagrams/01-media.dot) |
| Metadata and geography | [PNG](database-diagrams/02-metadata.png) | [SVG](database-diagrams/02-metadata.svg) | [DOT](database-diagrams/02-metadata.dot) |
| Albums, sharing and favorites | [PNG](database-diagrams/03-albums.png) | [SVG](database-diagrams/03-albums.svg) | [DOT](database-diagrams/03-albums.dot) |
| People and face recognition | [PNG](database-diagrams/04-people.png) | [SVG](database-diagrams/04-people.svg) | [DOT](database-diagrams/04-people.dot) |
| Tags, concepts and search | [PNG](database-diagrams/05-discovery.png) | [SVG](database-diagrams/05-discovery.svg) | [DOT](database-diagrams/05-discovery.dot) |
| Similar media | [PNG](database-diagrams/06-similarity.png) | [SVG](database-diagrams/06-similarity.svg) | [DOT](database-diagrams/06-similarity.dot) |
| Users and permissions | [PNG](database-diagrams/07-users.png) | [SVG](database-diagrams/07-users.svg) | [DOT](database-diagrams/07-users.dot) |
| Processing and background tasks | [PNG](database-diagrams/08-processing.png) | [SVG](database-diagrams/08-processing.svg) | [DOT](database-diagrams/08-processing.dot) |
| Events and version tracking | [PNG](database-diagrams/09-events.png) | [SVG](database-diagrams/09-events.svg) | [DOT](database-diagrams/09-events.dot) |
| Configuration, temporary and test tables | [PNG](database-diagrams/10-internal.png) | [SVG](database-diagrams/10-internal.svg) | [DOT](database-diagrams/10-internal.dot) |

**Legend:** `PK` = primary key, `FK` = foreign key, `U1`, `U2`, etc. = unique
key/index groups local to each table, `?` = nullable, `*` = inherited column.
Columns sharing a unique-key group number form one composite key.
Gray tables show cross-group references, with only primary and referenced columns.
Arrows point from foreign-key columns to referenced columns, not crow's-foot
cardinalities. Dashed arrows indicate PostgreSQL `INHERITS`, which does not
inherit primary, unique, or foreign-key constraints.

Only declared foreign keys are drawn; similarly named columns do not imply a
relationship. Defaults, checks, triggers, functions, non-unique indexes, and
function-created runtime tables are omitted.
The [parsed schema](database-diagrams/schema.json) is also included.
