#!/usr/bin/env Rscript
# Fetch the tables the site needs at render time from Redivis into data/.
# Used by CI (which has no local ETL output); requires REDIVIS_API_TOKEN.
# item_responses is not fetched — the site never loads it.

suppressMessages({
  library(redivis)
  library(arrow)
})

if (file.exists(".secrets")) readRenviron(".secrets")

# the rest of the site's data comes from the committed slices/responses;
# children carries the demographics that write_site_slices joins to admins.
#   Rscript etl/fetch_redivis_tables.R [version] [--all]
# version defaults to "current"; --all also fetches items, language_exposures
# and health_conditions (everything compute_derived.R needs)
args <- commandArgs(trailingOnly = TRUE)
version <- setdiff(args, "--all"); version <- if (length(version)) version[[1]] else "current"
tables <- c("instruments", "administrations", "children", "datasets")
if ("--all" %in% args) tables <- c(tables, "items", "language_exposures", "health_conditions")

dir.create("data", showWarnings = FALSE)
ds <- redivis$organization("datapages")$dataset("wordbank:627v", version = version)
for (t in tables) {
  message("fetching ", t)
  write_parquet(ds$table(t)$to_tibble(), file.path("data", paste0(t, ".parquet")))
}
